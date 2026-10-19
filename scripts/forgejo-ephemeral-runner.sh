#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Serve Forgejo Actions jobs with one throwaway macOS guest per job.
#
#   FORGEJO_URL=https://forgejo.example FORGEJO_TOKEN=<token> FORGEJO_SCOPE=<scope> \
#       scripts/forgejo-ephemeral-runner.sh [slots]
#   FORGEJO_URL=https://forgejo.example FORGEJO_REGISTRATION_TOKEN=<token> \
#       scripts/forgejo-ephemeral-runner.sh [slots]
#
# API mode (FORGEJO_TOKEN): FORGEJO_SCOPE is admin (instance-wide),
# orgs/<org>, repos/<owner>/<repo> or user, and the token needs the matching
# admin/write permission. Each slot registers an *ephemeral* runner through
# the Forgejo API (POST <scope>/actions/runners), boots a guest from GOLDEN
# with scripts/vm-job.sh, and runs `forgejo-runner one-job --wait` there. The
# runner token travels over SSH stdin into a mode-600 file.
#
# Registration-token mode (FORGEJO_REGISTRATION_TOKEN, the token from the
# Actions runner settings page): the guest itself runs `forgejo-runner
# register --ephemeral` and then `one-job --wait`. The registration token
# travels over SSH stdin, is used once and is never written to disk; a
# workflow can still read the guest's .runner file (this one runner's
# credential). A slot stops if registration fails, so a misconfiguration does
# not pile up runners. This mode cannot delete a registration, so a slot
# keeps its runner credential (the .runner file, sent back over the guest's
# stdout) in RUNNER_STATE_DIR while it has not taken a job, and hands it to
# the next guest instead of registering again: a guest that idles out leaves
# nothing behind in Forgejo.
#
# Either way the runner takes exactly one job, Forgejo (>= 15) deletes it
# afterwards, and the guest is discarded.
#
# Limits: a guest that gets no job within IDLE_TIMEOUT (default 900 s) is
# replaced by a fresh one. A job runs for at most JOB_TIMEOUT (default
# 1800 s), counted from when the runner picks it up, unless the job sets
# its own timeout-minutes, which then applies (plus JOB_TIMEOUT_GRACE, 300 s,
# for the runner to report it), up to JOB_MAX_TIMEOUT (default 10800 s, the
# Forgejo instance's own default limit). A job over its limit is cancelled
# through the runner, so Forgejo shows it as cancelled with its log.
#
# Environment: GOLDEN (needs ~/forgejo-runner and ~/node; default Tahoe v7),
# CPUS, RAM, RUNNER_LABELS (default macos-26-arm64:host,macos:host),
# FORGEJO_RUNNER_URL (instance URL as seen from the guest; default
# FORGEJO_URL; a Forgejo on the VM host itself is http://10.0.2.2:<port>),
# IDLE_TIMEOUT, JOB_TIMEOUT, JOB_TIMEOUT_GRACE, JOB_MAX_TIMEOUT (above),
# RUNNER_STATE_DIR (default ~/.local/state/vmapple-runner),
# FORGEJO_CACHE_SERVER + FORGEJO_CACHE_SECRET
# (a persistent `forgejo-runner cache-server` as seen from the guest, e.g.
# http://10.0.2.2:4100/ for one on the VM host; systemd/vmapple-runner-cache.service),
# so actions/cache survives the throwaway guests.
# GPU_SLOTS (slot numbers that boot with the paravirtual GPU; with GPU_GOLDEN,
# optional GPU_QEMU_BIN, GPU_VK_DRIVER_FILES, GPU_LABELS: see below).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Also accept the names of a runner-registration.env as Forgejo admins hand it out.
FORGEJO_URL="${FORGEJO_URL:-${FORGEJO_INSTANCE_URL:-}}"
FORGEJO_REGISTRATION_TOKEN="${FORGEJO_REGISTRATION_TOKEN:-${FORGEJO_RUNNER_REGISTRATION_TOKEN:-}}"
: "${FORGEJO_URL:?set FORGEJO_URL}"
if test -z "${FORGEJO_REGISTRATION_TOKEN:-}"; then
    : "${FORGEJO_TOKEN:?set FORGEJO_TOKEN (API mode) or FORGEJO_REGISTRATION_TOKEN}"
    : "${FORGEJO_SCOPE:?set FORGEJO_SCOPE (admin, orgs/ORG, repos/OWNER/REPO or user)}"
fi
slots="${1:-1}"
labels="${RUNNER_LABELS:-macos-26-arm64:host,macos:host}"
runner_url="${FORGEJO_RUNNER_URL:-$FORGEJO_URL}"
api="${FORGEJO_URL%/}/api/v1/${FORGEJO_SCOPE:-}/actions/runners"
export IDLE_TIMEOUT="${IDLE_TIMEOUT:-900}" JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"
export JOB_MAX_TIMEOUT="${JOB_MAX_TIMEOUT:-10800}"
job_timeout_grace="${JOB_TIMEOUT_GRACE:-300}"
for v in IDLE_TIMEOUT JOB_TIMEOUT JOB_MAX_TIMEOUT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a number of seconds" >&2; exit 2; }
done
[[ "$job_timeout_grace" =~ ^[0-9]+$ ]] || { echo "JOB_TIMEOUT_GRACE must be a number of seconds" >&2; exit 2; }
# vm-job.sh counts the idle and job limits from the runner's own log: work
# starts when it has fetched its task; it is stopped with SIGTERM, which
# cancels a running job and reports it, or ends an idle wait.
export JOB_START_PATTERN='single task poller successfully fetched one task'
export STOP_COMMAND="pkill -TERM -f 'forgejo-runner one-job'"
state_dir="${RUNNER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vmapple-runner}"
cache_server="${FORGEJO_CACHE_SERVER:-}"
cache_secret="${FORGEJO_CACHE_SECRET:-}"
if test -n "$cache_server" && test -z "$cache_secret"; then
    echo "FORGEJO_CACHE_SERVER needs FORGEJO_CACHE_SECRET" >&2; exit 2
fi
# Guest-side snippet: read the cache secret (the last stdin line) and, if set,
# write the runner config (with a cache section pointing the job's cache
# proxy at the shared server). Always passed with -c: zsh would not split a $cfg.
guest_cfg="read -r cs; umask 077; { printf 'log:\\n  level: debug\\n  job_level: info\\n'; if test -n \"\$cs\"; then printf 'cache:\\n  enabled: true\\n  external_server: %s\\n  secret: %s\\n' $(printf %q "$cache_server") \"\$cs\"; fi; } > ~/.runner-config.yml; unset cs"
# Start CoreSimulatorService and let it load its device sets before taking a
# job: the first xcodebuild after boot otherwise fails with "Unable to find a
# device matching the provided destination specifier" while it is still
# loading (no-op on images without Xcode).
guest_warm="if command -v xcrun >/dev/null && xcrun -f simctl >/dev/null 2>&1; then for i in \$(seq 60); do xcrun simctl list devices available 2>/dev/null | grep -qE '[(](Shutdown|Booted)[)]' && break; sleep 2; done; fi"
# A network outage can leave a negative answer for the forge in mDNSResponder's
# cache for up to an hour (the zone's SOA minimum), and the runner then polls a
# name it believes does not exist long after DNS is back. Every 30 s: if the
# system resolver has no address for the forge but a direct query to the
# configured nameserver has one, flush the cache. Output goes to a guest file:
# a background job holding the SSH session's stdout/stderr would keep the
# session open after the runner exits. No-op when the URL host is an address.
forge_host="${runner_url#*://}"; forge_host="${forge_host%%[/:]*}"
guest_dnswatch=":"
if ! [[ "$forge_host" =~ ^[0-9.]+$ ]] && test -n "$forge_host"; then
    guest_dnswatch="( h=$(printf %q "$forge_host"); while sleep 30; do dscacheutil -q host -a name \"\$h\" | grep -q ip_address && continue; host -W 3 \"\$h\" >/dev/null 2>&1 || continue; sudo -n dscacheutil -flushcache; sudo -n killall -HUP mDNSResponder; echo \"\$(date '+%F %T') flushed DNS cache: \$h was negatively cached\"; done ) </dev/null >>/tmp/dns-watchdog.log 2>&1 &"
fi
# Run the runner with debug logging, filtered in the guest: debug lines are
# dropped, except that the job's own timeout-minutes becomes a
# "vm-job: job-timeout=<s>" line for vm-job.sh (none set: JOB_TIMEOUT; an
# expression the runner evaluates itself: JOB_MAX_TIMEOUT). The filter writes
# to stderr, so the guest's stdout carries only what the slot sends back. At
# debug level the runner also copies every job's output to its stdout, which
# is discarded (Forgejo has the job log). A process substitution, not a pipe:
# zsh (MULTIOS) would send a redirected stdout into the pipe as well.
filter_prog='/level=(debug|trace)/ { if (!seen && index($0, "msg=\"Job.TimeoutMinutes: ")) { seen = 1; v = $0; sub(/.*msg="Job\.TimeoutMinutes: /, "", v); sub(/".*/, "", v); if (v ~ /^[0-9]+$/) s = v * 60 + grace; else if (v == "") s = def; else s = max; printf "vm-job: job-timeout=%d\n", s; fflush() } next } { print; fflush() }'
guest_run="~/forgejo-runner/forgejo-runner one-job --wait -c \$HOME/.runner-config.yml"
guest_filter=">/dev/null 2> >(awk -v def=$JOB_TIMEOUT -v max=$JOB_MAX_TIMEOUT -v grace=$job_timeout_grace $(printf %q "$filter_prog") >&2)"
export GOLDEN="${GOLDEN:-$HOME/vm-artifacts/tahoe-26.4-25E246-v7}" CPUS="${CPUS:-8}" RAM="${RAM:-16G}"

# GPU slots: the slot numbers in GPU_SLOTS (e.g. "2") boot with the paravirtual
# GPU (GFX=reims) from GPU_GOLDEN (an image with layer 65), optionally with their
# own GPU_QEMU_BIN / GPU_VK_DRIVER_FILES, and also offer GPU_LABELS (default
# macos-26-arm64-gpu:host), so jobs that need Metal (UI tests of apps that draw
# with Metal) can ask for one. A GPU slot also takes ordinary jobs.
# Out of process: GPU_BACKEND_BIN (reims-vgpu-backend) with GPU_OOP_QEMU_BIN (the
# QEMU from `MODE=oop scripts/build-qemu.sh`); without GPU_BACKEND_BIN the GPU
# slots run Reims in process from GPU_QEMU_BIN, so unsetting that one variable
# is the fallback. GPU_MAX_REFRESH_HZ and GPU_FRAME_PACING reach the GPU slots'
# launcher unchanged; slots without the GPU ignore all of these.
gpu_slots=" ${GPU_SLOTS:-} "; gpu_slots="${gpu_slots//,/ }"
gpu_labels="${GPU_LABELS:-macos-26-arm64-gpu:host}"
label_args_for() {
    local l out="" list
    IFS=',' read -r -a list <<<"$1"
    for l in "${list[@]}"; do out+=" --label $(printf %q "$l")"; done
    printf '%s' "$out"
}

register() {
    local name="$1"
    curl -sSf -X POST -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"description\":\"vmapple ephemeral macOS guest\",\"ephemeral\":true}" "$api"
}

slot() {
    local n="$1" name reply id uuid token labels="$labels" label_args
    if [[ "$gpu_slots" == *" $n "* ]]; then
        export GFX=reims GOLDEN="${GPU_GOLDEN:?GPU_SLOTS needs GPU_GOLDEN (an image with layer 65)}"
        # Out of process when GPU_BACKEND_BIN is set: that QEMU is
        # GPU_OOP_QEMU_BIN. Unsetting GPU_BACKEND_BIN alone falls back to the
        # in-process GPU_QEMU_BIN.
        if test -n "${GPU_BACKEND_BIN:-}"; then
            export QEMU_BIN="${GPU_OOP_QEMU_BIN:?GPU_BACKEND_BIN needs GPU_OOP_QEMU_BIN (a QEMU with apv-gpu-proxy)}"
        else
            test -n "${GPU_QEMU_BIN:-}" && export QEMU_BIN="$GPU_QEMU_BIN"
        fi
        test -n "${GPU_VK_DRIVER_FILES:-}" && export VK_DRIVER_FILES="$GPU_VK_DRIVER_FILES"
        labels="$labels,$gpu_labels"
        echo "[slot $n] GPU slot: $GOLDEN, labels $labels" >&2
    fi
    label_args="$(label_args_for "$labels")"
    # Slot N gets its own LAN tap and a stable MAC when NET_TAP_PREFIX is set.
    if test -n "${NET_TAP_PREFIX:-}"; then
        export TAP_IF="${NET_TAP_PREFIX}$n" TAP_MAC="$(printf '52:54:00:76:62:%02x' "$n")"
    fi
    # Registration-token mode keeps the slot's unused runner credential in
    # $cred.runner as "<name> <labels>|<url> <base64 .runner>"; a guest that
    # registers sends its .runner back on stdout ($cred.new, adopted with the
    # name and key in $cred.pending), and vm-job.sh touches $cred.started once
    # the runner has fetched a job. Files survive a service restart.
    local cred="$state_dir/forgejo-slot-$n" key="$labels|$runner_url" t r rname st
    umask 077   # this slot's subshell only: the credential files
    while true; do
        name="vmapple-$(hostname -s)-$n-$(date +%Y%m%d%H%M%S)"
        if test -n "${FORGEJO_REGISTRATION_TOKEN:-}"; then
            if test -s "$cred.new" && test -s "$cred.pending"; then
                printf '%s %s\n' "$(<"$cred.pending")" "$(<"$cred.new")" > "$cred.runner"
            fi
            rm -f "$cred.new" "$cred.pending"
            # A runner that took a job is deleted by Forgejo once the job ends.
            if test -e "$cred.started" || { test -s "$cred.runner" && test "$(cut -d' ' -f2 "$cred.runner")" != "$key"; }; then
                rm -f "$cred.runner"
            fi
            rm -f "$cred.started"
            if test -s "$cred.runner"; then
                read -r rname _ r < "$cred.runner"
                t=
                echo "[slot $n] $rname has had no job yet; reusing it in a fresh guest" >&2
            else
                rname="$name" r= t="$FORGEJO_REGISTRATION_TOKEN"
                printf '%s %s\n' "$name" "$key" > "$cred.pending"
                echo "[slot $n] $name registering in a fresh guest" >&2
            fi
            printf '%s\n' "$t" "$r" "$cache_secret" | JOB_STARTED_FILE="$cred.started" "$repo_root/scripts/vm-job.sh" \
                "read -r t; read -r r; $guest_cfg; $guest_warm; $guest_dnswatch; cd ~ && if test -n \"\$r\"; then printf %s \"\$r\" | base64 --decode > .runner || exit 78; else ~/forgejo-runner/forgejo-runner register --no-interactive --ephemeral --instance $(printf %q "$runner_url") --token \"\$t\" --name $name --labels $(printf %q "$labels") >&2 || exit 77; base64 < .runner | tr -d '\\n'; echo; fi; unset t r; $guest_run $guest_filter" \
                > "$cred.new"
            st=$?
            echo "[slot $n] $rname finished with status $st" >&2
            case "$st" in
            123|125)    # no job taken: the registration stays for the next guest
                test "$st" = 125 && sleep 30 ;;   # guest never booted (after retries)
            77)
                rm -f "$cred.new" "$cred.pending"
                echo "[slot $n] registration failed (token, URL, or Forgejo < 15); stopping this slot" >&2
                return 1 ;;
            *)          # took a job, or the runner refused the credential: register afresh
                rm -f "$cred.runner" "$cred.new" "$cred.pending" ;;
            esac
            continue
        fi
        if ! reply="$(register "$name")"; then
            echo "[slot $n] runner registration failed; retrying in 60 s" >&2
            sleep 60; continue
        fi
        read -r id uuid token < <(python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["id"], r["uuid"], r["token"])' <<<"$reply")
        echo "[slot $n] $name (id $id) waiting for a job" >&2
        printf '%s\n' "$token" "$cache_secret" | "$repo_root/scripts/vm-job.sh" \
            "read -r t; $guest_cfg; $guest_warm; $guest_dnswatch; umask 077; printf %s \"\$t\" > ~/.forgejo-runner-token; cd ~ && $guest_run --url $(printf %q "$runner_url") --uuid $uuid --token-url file://\$HOME/.forgejo-runner-token$label_args $guest_filter"
        echo "[slot $n] $name finished with status $?" >&2
        # Ephemeral runners are removed by Forgejo after their job; remove a
        # registration left behind by a timeout or a guest that never booted.
        curl -s -o /dev/null -X DELETE -H "Authorization: token $FORGEJO_TOKEN" "$api/$id" || true
    done
}

mkdir -p "$state_dir" && chmod 700 "$state_dir" || exit 1
# Stopping the orchestrator stops every slot; each vm-job then shuts its guest down.
trap 'trap - INT TERM; kill -TERM 0 2>/dev/null; wait; exit 130' INT TERM
for n in $(seq 1 "$slots"); do slot "$n" & done
wait

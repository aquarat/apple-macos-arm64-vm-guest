#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run one command in a throwaway macOS guest and discard the guest afterwards.
#
#   scripts/vm-job.sh <command...>          # runs in the guest via SSH; stdin is passed through
#
# Environment: GOLDEN (bundle dir), CPUS (4), RAM (12G), BOOT_TIMEOUT (90 s),
# JOB_TIMEOUT (3600 s), KEEP=1 to keep the guest's disk after the job,
# RUNNER_KEY (~/.ssh/vmapple_runner), BOOT_RETRIES (2: a guest that never
# reaches SSH is discarded and booted again from a fresh clone),
# KEEP_ON_BOOT_FAIL=1 to leave such a guest running for inspection,
# BALLOON=1 (+ BALLOON_GOVERNOR=0 to skip the governor; tunables in
# scripts/balloon-governor.py). Launcher settings (GFX, VK_DRIVER_FILES, AUDIO,
# TAP_IF, QEMU_BIN, ...) pass through vm-run.sh to scripts/launch-kvm.sh.
# Logs end up in artifacts/job-logs/<job>/.
#
# Waiting for work (runners that wait for a job before running it):
# JOB_START_PATTERN (an extended regex) marks the command's stderr line that
# says the real work has started. With it, IDLE_TIMEOUT (s, 0 = none) limits
# the wait for that line and JOB_TIMEOUT counts from it instead of from boot.
# The command can set its own limit by printing "vm-job: job-timeout=<s>" on
# stderr once it knows it (capped at JOB_MAX_TIMEOUT, default JOB_TIMEOUT).
# STOP_COMMAND, run in the guest over a second SSH session, asks the command
# to stop on its own (e.g. so a runner reports a cancelled job) before the
# session is killed STOP_GRACE (60 s) later. JOB_STARTED_FILE (default in the
# run directory) is where the start time is written, for a caller that wants
# to know afterwards whether the work had started.
#
# The guest is a reflink clone of the golden bundle (scripts/vm-run.sh), so a
# job never changes the golden image, and its memory is returned to the host
# when QEMU exits. Exit status: the command's status, or 124 for a job
# timeout, 123 for an idle timeout (JOB_START_PATTERN never seen), 125 for a
# guest that never reached SSH, 120 when the out-of-process GPU backend
# (GPU_BACKEND_BIN) was lost: QEMU stops the guest, the reason is logged here as
# "job failed: GPU backend lost: ...", and the guest is discarded without
# waiting for the job's timeout. A job already being stopped for a timeout
# keeps its 123/124; a backend loss during that stop is only logged.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key="${RUNNER_KEY:-$HOME/.ssh/vmapple_runner}"
boot_timeout="${BOOT_TIMEOUT:-90}"
job_timeout="${JOB_TIMEOUT:-3600}"
job_max_timeout="${JOB_MAX_TIMEOUT:-$job_timeout}"
idle_timeout="${IDLE_TIMEOUT:-0}"
start_pattern="${JOB_START_PATTERN:-}"
stop_grace="${STOP_GRACE:-60}"
export CPUS="${CPUS:-4}" RAM="${RAM:-12G}"
# vmapple2 host kernels emulate the no-syndrome GIC store; no GDB hand-off needed.
export INJECT="${INJECT:-0}"

test $# -gt 0 || { echo "usage: $0 <command...>" >&2; exit 2; }

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
export SSH_PORT="$(free_port)" GDB_PORT="$(free_port)"
name="job-$(date +%Y%m%d-%H%M%S)-$$"
run="$repo_root/artifacts/runs/$name"
ssh_opts=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -p "$SSH_PORT" aquarat@127.0.0.1)
log() { echo "[vm-job $name $(date +%T)] $*" >&2; }

qemu_alive() {
    local pid
    pid="$(cat "$run/launcher.pid" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null
}

# The reason QEMU's apv-gpu-proxy device printed when its backend died, if it did.
gpu_lost() {
    grep -m1 -o 'apv-gpu-proxy: GPU backend lost: .*' "$run/logs/launcher.log" 2>/dev/null
}
gpu_lost_exit() {
    local why="$1" ended quarantined
    ended="$(grep -h '^gpu backend: \(ended\|exited\)' "$run/logs/gpu-backend.log" \
        "${GPU_BACKEND_LOG:-/dev/null}" 2>/dev/null | tail -1)"
    if test -n "${GPU_BACKEND_BIN:-}"; then
        # Before the guest is discarded: a breadcrumb left by a driver call
        # that never returned goes into the host's quarantine now.
        quarantined="$(REIMS_VGPU_BREADCRUMB_DIR="$run/logs/gpu-breadcrumbs" \
            "$GPU_BACKEND_BIN" --fold-breadcrumbs 2>/dev/null)"
    fi
    log "job failed: GPU backend lost: ${why#apv-gpu-proxy: GPU backend lost: }${ended:+ ($ended)}${quarantined:+; $quarantined}"
    gpu_failed=1
    exit 120
}

booted=0
gpu_failed=0
governor_pid=
cleanup() {
    # Finish cleaning up even if more INT/TERM arrive (a service stop signals
    # every process, then the orchestrator signals its group again).
    trap '' INT TERM
    if test -n "$governor_pid"; then
        kill "$governor_pid" 2>/dev/null; wait "$governor_pid" 2>/dev/null; governor_pid=
    fi
    # A guest that never reached SSH cannot be shut down over SSH; skip
    # straight to QMP quit instead of waiting out the SSH and power-off timeouts.
    # A guest stopped by a lost GPU backend cannot shut down; quit QEMU.
    if qemu_alive && test "$booted" = 1 && test "$gpu_failed" = 0; then
        log "shutting guest down"
        timeout 20 ssh -n "${ssh_opts[@]}" 'sudo -n shutdown -h now' >/dev/null 2>&1
        for _ in $(seq 1 60); do qemu_alive || break; sleep 2; done
    fi
    if qemu_alive; then
        log "guest did not power off; QMP quit"
        "$repo_root/scripts/vm-run.sh" quit "$name" >/dev/null 2>&1
        for _ in $(seq 1 15); do qemu_alive || break; sleep 1; done
    fi
    if qemu_alive; then
        log "QEMU still running; killing launcher group"
        kill -TERM -- "-$(cat "$run/launcher.pid")" 2>/dev/null
        sleep 3
    fi
    if test "${KEEP:-0}" != 1; then
        mkdir -p "$repo_root/artifacts/job-logs"
        mv "$run/logs" "$repo_root/artifacts/job-logs/$name" 2>/dev/null
        cp "$run/env.txt" "$repo_root/artifacts/job-logs/$name/" 2>/dev/null
        rm -rf "$run"
    fi
}
trap cleanup EXIT
trap 'test -n "${job_pid:-}" && kill "$job_pid" 2>/dev/null; exit 130' INT TERM

boot() {
    local t0
    # start may wait for a macOS instance slot (licence limit, see vm-run.sh).
    "$repo_root/scripts/vm-run.sh" start "$name" >/dev/null || return 1
    t0=$(date +%s)
    log "booting (cpus=$CPUS ram=$RAM ssh=127.0.0.1:$SSH_PORT)"
    until timeout 10 ssh -n "${ssh_opts[@]}" true 2>/dev/null; do
        why="$(gpu_lost)" && gpu_lost_exit "$why"
        qemu_alive || { log "QEMU exited during boot"; return 1; }
        if (( $(date +%s) - t0 > boot_timeout )); then
            log "no SSH after ${boot_timeout}s"; return 1
        fi
        sleep 2
    done
    booted=1
}

t0=$(date +%s)
attempt=0
until boot; do
    if test "${KEEP_ON_BOOT_FAIL:-0}" = 1; then
        log "leaving $name running for inspection"
        trap - EXIT; exit 125
    fi
    cleanup
    booted=0
    attempt=$((attempt + 1))
    (( attempt <= ${BOOT_RETRIES:-2} )) || exit 125
    name="$name-r$attempt"; run="$repo_root/artifacts/runs/$name"
    log "retrying boot ($attempt) from a fresh clone"
done
t1=$(date +%s)
log "guest ready after $((t1 - t0))s; running job"
# BALLOON=1: size the guest's balloon to its needs while the job runs
# (BALLOON_GOVERNOR=0 to drive it by hand; tunables: balloon-governor.py).
if test "${BALLOON:-0}" = 1 && test "${BALLOON_GOVERNOR:-1}" = 1; then
    "$repo_root/scripts/balloon-governor.py" \
        --qmp "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple/$name.balloon.qmp" \
        --ssh-port "$SSH_PORT" --key "$key" > "$run/logs/balloon-governor.log" 2>&1 < /dev/null &
    governor_pid=$!
fi
# Background + wait so INT/TERM interrupt a long-running job immediately
# (bash defers traps until a foreground command returns); <&0 keeps stdin.
if test -z "$start_pattern"; then
    timeout "$job_timeout" ssh "${ssh_opts[@]}" "$@" <&0 &
    job_pid=$!
    # Poll for a lost GPU backend while the job runs: QEMU stops the guest, so
    # the job would otherwise sit out its whole timeout.
    while kill -0 "$job_pid" 2>/dev/null; do
        if why="$(gpu_lost)"; then
            kill "$job_pid" 2>/dev/null; wait "$job_pid" 2>/dev/null
            log "job exit 120 after $(( $(date +%s) - t1 ))s"
            gpu_lost_exit "$why"
        fi
        sleep 2 & wait $!
    done
    wait "$job_pid"
    status=$?
    log "job exit $status after $(( $(date +%s) - t1 ))s"
    exit "$status"
fi

# JOB_START_PATTERN: pass the command's stderr through, noting (in files, as
# the filter runs in a subshell) when the work starts and any limit it asks for.
started_file="${JOB_STARTED_FILE:-$run/job-started}" limit_file="$run/job-limit"
watch_stderr() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^vm-job:\ job-timeout=([0-9]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}" > "$limit_file"
        elif ! test -e "$started_file" && [[ "$line" =~ $start_pattern ]]; then
            date +%s > "$started_file"
        fi
        printf '%s\n' "$line" >&2
    done
}
forced=
stop_job() {    # stop_job <status> <reason>
    local i
    log "$2; stopping the job"
    forced="$1"
    if test -n "${STOP_COMMAND:-}"; then
        timeout 20 ssh -n "${ssh_opts[@]}" "$STOP_COMMAND" >/dev/null 2>&1
        for ((i = 0; i < stop_grace; i += 2)); do
            kill -0 "$job_pid" 2>/dev/null || return
            # A guest stopped by a lost GPU backend cannot stop its job.
            gpu_lost >/dev/null && break
            sleep 2
        done
        log "the job did not stop within ${stop_grace}s; ending its session"
    fi
    kill "$job_pid" 2>/dev/null
}
ssh "${ssh_opts[@]}" "$@" <&0 2> >(watch_stderr) &
job_pid=$!
while kill -0 "$job_pid" 2>/dev/null; do
    if why="$(gpu_lost)"; then
        kill "$job_pid" 2>/dev/null; wait "$job_pid" 2>/dev/null
        log "job exit 120 after $(( $(date +%s) - t1 ))s"
        gpu_lost_exit "$why"
    fi
    now=$(date +%s)
    if test -s "$started_file"; then
        limit="$job_timeout"
        test -s "$limit_file" && limit="$(<"$limit_file")"
        (( limit > job_max_timeout )) && limit="$job_max_timeout"
        if (( now - $(<"$started_file") >= limit )); then
            stop_job 124 "job ran for ${limit}s, its limit"; break
        fi
    elif (( idle_timeout > 0 && now - t1 >= idle_timeout )); then
        stop_job 123 "no job after ${idle_timeout}s"
        # A job that started while the runner was being stopped was cut short.
        test -e "$started_file" && forced=124
        break
    fi
    sleep 2 & wait $!
done
wait "$job_pid"
status=$?
test -n "$forced" && status="$forced"
# The status of a job stopped for a timeout stays the timeout's; a backend lost
# while it was stopping is noted, and the frozen guest is quit, not shut down.
if test -n "$forced" && why="$(gpu_lost)"; then
    log "GPU backend lost while the job was being stopped: ${why#apv-gpu-proxy: GPU backend lost: }"
    gpu_failed=1
fi
log "job exit $status after $(( $(date +%s) - t1 ))s ($(test -e "$started_file" && echo "work started $(( $(<"$started_file") - t1 ))s in" || echo "no work started"))"
exit "$status"

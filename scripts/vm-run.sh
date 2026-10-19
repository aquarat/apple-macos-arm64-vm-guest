#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# One VM per invocation, from a read-only golden bundle.
#
#   GOLDEN=~/vm-artifacts/<bundle> scripts/vm-run.sh start <name>   [env passed to launch-gui-kvm.sh / launch-kvm.sh]
#   scripts/vm-run.sh status <name>
#   scripts/vm-run.sh qmp <name> '<json command>'
#   scripts/vm-run.sh screenshot <name>     # writes artifacts/runs/<name>/screen-<time>.png
#   scripts/vm-run.sh quit <name>
#
# start reflink-clones disk.img and aux.img.trimmed (btrfs: instant, no space
# until the guest writes), so the golden bundle is never opened read-write.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs="$repo_root/artifacts/runs"
golden="${GOLDEN:-$HOME/vm-artifacts/ventura-13.6-22G120-v2}"
booter="${AVPBOOTER:-$repo_root/artifacts/firmware/AVPBooter.vmapple2.mBoot-18000.101.7.bin}"
sock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vmapple"
# Default Vulkan driver: llvmpipe (software). It cannot run the iOS simulator;
# GPU slots set VK_DRIVER_FILES to the patched Honeykrisp from
# scripts/host-gpu-setup.sh (see docs/NOTES.md, "QEMU / Reims build").
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/lvp_icd.aarch64.json}"

die() { echo "error: $*" >&2; exit 1; }
name="${2:-}"; test -n "$name" || die "usage: $0 start|status|qmp|screenshot|quit <name>"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad run name"
run="$runs/$name"
qmp="$sock_dir/$name.qmp"
# The GPU backend socket goes beside it: the run directory is too long a path
# for a unix socket (108 bytes) on hosts with a deep checkout.
gpu_sock="$sock_dir/$name.gpu"

qmp_call() {
    printf '%s\n' '{"execute":"qmp_capabilities"}' "$1" |
        socat -t"${QMP_WAIT:-3}" - "UNIX-CONNECT:$qmp" | tail -n +3
}

# Apple's macOS licence allows two virtualised macOS instances per Mac. The
# aquarat QEMU fork enforces it (vmapple machine property max-instances,
# default 2: each guest holds an abstract socket @vmapple-macos-instance-N
# and a third QEMU refuses to start); start waits here for a free slot
# instead. QEMUs without the check are counted by process. Stop the runner
# service before baking on a runner host, or the bake waits for a slot.
# MACOS_MAX_INSTANCES (2; 0 = no wait), MACOS_SLOT_WAIT (seconds, 86400).
wait_for_instance_slot() {
    local max="${MACOS_MAX_INSTANCES:-2}" limit="${MACOS_SLOT_WAIT:-86400}"
    local waited=0 n p q
    test "$max" -gt 0 || return 0
    while :; do
        n=$(grep -c '@vmapple-macos-instance-' /proc/net/unix 2>/dev/null || true)
        p=0
        for q in $(pgrep -x qemu-system-aar); do
            if tr '\0' ' ' < "/proc/$q/cmdline" 2>/dev/null | grep -q -- '-machine vmapple'; then
                p=$((p + 1))
            fi
        done
        n=${n:-0}
        if (( p > n )); then n=$p; fi
        if (( n < max )); then return 0; fi
        if (( waited == 0 )); then
            echo "waiting for a macOS instance slot ($n of $max in use)" >&2
        fi
        if (( waited >= limit )); then die "no macOS instance slot free after ${limit}s"; fi
        sleep 10
        waited=$((waited + 10))
    done
}

case "$1" in
start)
    wait_for_instance_slot
    if test "${RESUME:-0}" = 1; then
        # Boot an existing run's disk again (e.g. after a single-user bake).
        test -f "$run/disk.img" || die "$run has no disk to resume"
        mv "$run/logs" "$run/logs.$(date +%H%M%S)" 2>/dev/null || true
    else
        test ! -e "$run" || die "$run exists"
    fi
    mkdir -p "$run/logs" "$sock_dir"
    if test "${RESUME:-0}" != 1; then
        for f in disk.img aux.img.trimmed vm.json; do
            cp --reflink=always "$golden/guest/$f" "$run/$f"
            chmod u+w "$run/$f"
        done
    fi
    env | grep -E '^(CPUS|RAM|NET_DEVICE_OPTS|TAP_IF|TAP_MAC|INJECT|KVM_MMIO_PATCH|VMAPPLE_HANDOFF_PC|GFX|CONSOLE|XNU_BOOT_ARGS|CSR_CONFIG|QEMU_EXTRA_ARGS|REIMS_[A-Z_]+|VK_[A-Z_]+|MESA_[A-Z_]+|SSH_PORT|SSH_BIND|MEMFD|BALLOON[A-Z_]*|AUDIO[A-Z_]*)=' \
        > "$run/env.txt" || true
    echo "golden=$golden booter=$booter" >> "$run/env.txt"
    # Reims keeps its Vulkan pipeline cache (one file per driver build) and its
    # driver quarantine in TMPDIR. /tmp is wiped at every host boot, so every
    # boot recompiled every pipeline: give QEMU a persistent TMPDIR instead
    # (REIMS_VGPU_TMPDIR). Translation scratch directories of QEMUs that have
    # exited (reims-vgpu-m2v-cache-<pid>) are pruned here.
    reims_tmp="${REIMS_VGPU_TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/reims-vgpu}"
    mkdir -p "$reims_tmp"
    for d in "$reims_tmp"/reims-vgpu-m2v-cache-*; do
        test -d "$d" || continue
        kill -0 "${d##*-}" 2>/dev/null || rm -rf -- "$d"
    done
    echo "REIMS_VGPU_TMPDIR=$reims_tmp" >> "$run/env.txt"
    # Reims' failure log defaults to an uncapped file in /tmp (often RAM; ~25 MB
    # per 10 min of simulator UI tests): keep it with the run's logs, where a
    # named path gets Reims' 64 MiB cap, and leave the verbose draw log off.
    (
        cd "$repo_root"
        TMPDIR="$reims_tmp" \
        GUEST_DIR="$run" AVPBOOTER="$booter" LOG_DIR="$run/logs" QMP_SOCKET="$qmp" \
            GPU_BACKEND_SOCKET="${GPU_BACKEND_SOCKET:-$gpu_sock}" \
            REIMS_VGPU_WINDOW="${REIMS_VGPU_WINDOW:-0}" CONSOLE="${CONSOLE:-none}" \
            REIMS_VGPU_FAIL_LOG="${REIMS_VGPU_FAIL_LOG:-$run/logs/reims-fail.log}" \
            REIMS_VGPU_DRAW_LOG_PATH="${REIMS_VGPU_DRAW_LOG_PATH:-off}" \
            setsid nohup scripts/launch-gui-kvm.sh > "$run/logs/launcher.log" 2>&1 < /dev/null &
        echo $! > "$run/launcher.pid"
    )
    echo "started $name: $run"
    ;;
status)
    qmp_call '{"execute":"query-status"}'
    qmp_call '{"execute":"human-monitor-command","arguments":{"command-line":"info registers"}}' |
        grep -o 'PC=[0-9a-f]*' || true
    ;;
qmp) qmp_call "${3:?json}" ;;
screenshot)
    t="$(date +%H%M%S)"
    qmp_call "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$run/screen-$t.ppm\"}}" >/dev/null
    magick "$run/screen-$t.ppm" -resize 50% "$run/screen-$t.png" && rm -f "$run/screen-$t.ppm"
    echo "$run/screen-$t.png"
    ;;
quit) qmp_call '{"execute":"quit"}' || true ;;
*) die "unknown command $1" ;;
esac

#!/usr/bin/env bash
# Launch one macOS guest with KVM in QEMU's vmapple machine (foreground).
# Usually called through scripts/vm-run.sh / vm-job.sh, or
# scripts/launch-gui-kvm.sh (GDB hand-off; INJECT=0 skips it).
#
# Environment (defaults in brackets):
#   QEMU_BIN      [build/qemu-fleet, else older build dirs]
#   GUEST_DIR     bundle dir with disk.img, aux.img.trimmed, vm.json [artifacts/guest]
#   AVPBOOTER     [~/Downloads/AVPBooter.vmapple2.bin]
#   CPUS [8], RAM [8G], CPU_MODEL [host]
#   GFX           reims (paravirtual GPU) | none [reims]; renderer: VK_DRIVER_FILES
#   MEMFD         1 = guest RAM on a shared memfd [1 with GFX=reims or BALLOON=1]
#   BALLOON       1 = virtio balloon with macos-units [0]; BALLOON_OPTS, BALLOON_QMP
#   AUDIO         virtio | usb | none [virtio]; AUDIO_OPTS
#   SSH_PORT [2222], SSH_BIND [127.0.0.1], GUEST_MAC, NET_DEVICE_OPTS
#   TAP_IF, TAP_MAC  optional second NIC on an existing tap
#   DISK_CACHE    [unsafe]; LOG_DIR [logs/]; SERIAL; QMP_SOCKET
#   GDB_PORT, PAUSE_AT_START (on|off), CONSOLE (reims|none|gtk),
#   REIMS_VGPU_WINDOW (0 = no host window), QEMU_EXTRA_ARGS
#   GPU_BACKEND_BIN  run the GPU device model out of process: path to
#                 reims-vgpu-backend, for a QEMU with the apv-gpu-proxy device.
#                 GPU_BACKEND_SOCKET [LOG_DIR/gpu-backend.sock],
#                 GPU_BACKEND_LOSS stop | reset | shutdown [stop],
#                 GPU_BACKEND_LOG [LOG_DIR/gpu-backend.log]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fleet_qemu="$repo_root/build/qemu-fleet/vendor/qemu/build/qemu-system-aarch64"
gui_qemu="$repo_root/build/reims-linux-product/vendor/qemu/build/qemu-system-aarch64"
development_gui_qemu="$repo_root/build/reims-linux/vendor/qemu/build/qemu-system-aarch64"
headless_qemu="$repo_root/build/experiment-macOS-arm64-on-linux-x86/build/qemu-system-aarch64"
if test -n "${QEMU_BIN:-}"; then
    qemu="$QEMU_BIN"
elif test -x "$fleet_qemu"; then
    qemu="$fleet_qemu"
elif test -x "$gui_qemu"; then
    qemu="$gui_qemu"
elif test -x "$development_gui_qemu"; then
    qemu="$development_gui_qemu"
else
    qemu="$headless_qemu"
fi
guest_dir="${GUEST_DIR:-$repo_root/artifacts/guest}"
booter="${AVPBOOTER:-$HOME/Downloads/AVPBooter.vmapple2.bin}"
ram="${RAM:-8G}"
cpus="${CPUS:-8}"
cpu_model="${CPU_MODEL:-host}"
ssh_port="${SSH_PORT:-2222}"
guest_mac="${GUEST_MAC:-52:54:00:76:61:70}"
# Guest disks are throwaway clones (jobs) or promoted only after a clean
# shutdown (bakes), so guest flushes need not reach the host disk:
# cache=unsafe keeps fsync-heavy work (xip, xcodebuild) fast on btrfs.
# DISK_CACHE=writeback honours guest flushes.
disk_cache="${DISK_CACHE:-unsafe}"
log_dir="${LOG_DIR:-$repo_root/logs}"
serial="${SERIAL:-}"
qmp_socket_override="${QMP_SOCKET:-}"
gdb_port="${GDB_PORT:-}"
pause_at_start="${PAUSE_AT_START:-off}"
console="${CONSOLE:-reims}"
gfx="${GFX:-reims}"
ssh_bind="${SSH_BIND:-127.0.0.1}"
read -r -a extra_args <<<"${QEMU_EXTRA_ARGS:-}"
# BALLOON=1: virtio balloon for scripts/balloon-governor.py (vm-job.sh starts
# one per guest) or scripts/balloon-squeeze.sh. The macOS driver needs
# macos-units (aquarat QEMU fork, see docs/NOTES.md "Memory balloon") and
# stats polling (it wakes on the stats interrupt). The governor gets a QMP
# monitor of its own (BALLOON_QMP, default <QMP_SOCKET>.balloon.qmp).
if test "${BALLOON:-0}" = 1; then
    extra_args+=(-device "virtio-balloon-pci,id=balloon0,macos-units=on,guest-stats-polling-interval=5${BALLOON_OPTS:+,$BALLOON_OPTS}")
    balloon_qmp="${BALLOON_QMP:-${QMP_SOCKET:+${QMP_SOCKET%.qmp}.balloon.qmp}}"
    if test -n "$balloon_qmp"; then
        rm -f "$balloon_qmp"
        extra_args+=(-qmp "unix:$balloon_qmp,server=on,wait=off")
    fi
fi
# Optional second NIC on a pre-created tap (e.g. bridged to the LAN, see
# scripts/host-net-setup.sh); the user-mode NIC stays the management path.
tap_if="${TAP_IF:-}"
tap_mac="${TAP_MAC:-52:54:00:76:62:01}"
if test -n "$tap_if"; then
    test -d "/sys/class/net/$tap_if" || { echo "error: no tap device $tap_if" >&2; exit 1; }
    extra_args+=(-netdev "tap,id=net1,ifname=$tap_if,script=no,downscript=no"
                 -device "virtio-net-pci,netdev=net1,mac=$tap_mac")
fi

# The patched KVM QEMU forwards Apple's private VMApple PAuth HVC range and
# implements it in userspace. Keep the opt-in explicit in QEMU itself while
# making this repository's dedicated launcher select the required contract.
export QEMU_VMAPPLE_KVM_HVC="${QEMU_VMAPPLE_KVM_HVC:-1}"

die() { echo "error: $*" >&2; exit 1; }

"$repo_root/scripts/check-host.sh" >/dev/null
test -f "$booter" || die "AVPBooter not found: $booter"
test -f "$guest_dir/aux.img.trimmed" || die "missing $guest_dir/aux.img.trimmed"
test -f "$guest_dir/disk.img" || die "missing $guest_dir/disk.img"
test -f "$guest_dir/vm.json" || die "missing $guest_dir/vm.json"

ecid="$("$repo_root/scripts/extract-ecid.py" "$guest_dir/vm.json")"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
serial_log="$log_dir/serial-$stamp.log"
qmp_socket="${qmp_socket_override:-$log_dir/qmp-$stamp.sock}"
if test -z "$serial"; then
    serial="file:$serial_log"
fi
machine="vmapple,uuid=$ecid,accel=kvm"
display_args=(-display none)
debug_args=()
if test -n "$gdb_port"; then
    [[ "$gdb_port" =~ ^[0-9]+$ ]] || die "GDB_PORT must be numeric"
    debug_args+=(-gdb "tcp:127.0.0.1:$gdb_port")
fi
if test "$pause_at_start" = on; then
    debug_args+=(-S)
elif test "$pause_at_start" != off; then
    die "PAUSE_AT_START must be on or off"
fi
device_help="$({ "$qemu" -device reims-vgpu-mmio,help 2>&1 || true; })"
proxy_help="$({ "$qemu" -device apv-gpu-proxy,help 2>&1 || true; })"
# Guest RAM on a shared memfd (MEMFD=1; the default with the GPU or the
# balloon, MEMFD=0 for anonymous RAM):
# - Reims maps fragmented guest pages (textures, render targets) through a
#   packed view of the RAM's backing file; with anonymous RAM, draws using
#   scattered pages fail.
# - The balloon frees 16 KiB pages inside 32 MiB transparent huge pages.
#   Punching a hole in a memfd splits the huge page and frees the memory at
#   once; MADV_DONTNEED on anonymous RAM only queues the huge page for a
#   deferred split, which the kernel runs under memory pressure, so the host
#   gets nothing back (and khugepaged may refill the hole).
# Needs shmem THP set to advise (scripts/host-gpu-setup.sh) for huge pages.
memfd_default=0
if test "$gfx" = reims || test "${BALLOON:-0}" = 1; then memfd_default=1; fi
if test "${MEMFD:-$memfd_default}" = 1; then
    extra_args+=(-object "memory-backend-memfd,id=guest-ram,size=$ram,share=on")
    machine+=",memory-backend=guest-ram"
fi
if test "$gfx" = none; then
    # No paravirtual GPU (needs a QEMU with gfx-device=none): headless only.
    machine+=",gfx-device=none"
fi
if test "$gfx" = reims && test -n "${GPU_BACKEND_BIN:-}"; then
    # The GPU device model in its own process: QEMU's apv-gpu-proxy device
    # connects to the backend's socket. The backend inherits this
    # environment (VK_DRIVER_FILES, REIMS_VGPU_*, TMPDIR); when QEMU exits the
    # backend sees the socket close and exits too.
    grep -q '^apv-gpu-proxy options:' <<<"$proxy_help" ||
        die "$qemu has no apv-gpu-proxy device (GPU_BACKEND_BIN set)"
    test -x "$GPU_BACKEND_BIN" || die "GPU_BACKEND_BIN not executable: $GPU_BACKEND_BIN"
    mkdir -p "$log_dir"
    gpu_sock="${GPU_BACKEND_SOCKET:-$log_dir/gpu-backend.sock}"
    rm -f "$gpu_sock"
    gpu_log="${GPU_BACKEND_LOG:-$log_dir/gpu-backend.log}"
    "$GPU_BACKEND_BIN" --socket "$gpu_sock" >> "$gpu_log" 2>&1 < /dev/null &
    gpu_backend_pid=$!
    for _ in $(seq 1 100); do
        test -S "$gpu_sock" && break
        kill -0 "$gpu_backend_pid" 2>/dev/null || die "GPU backend exited at start (see $gpu_log)"
        sleep 0.1
    done
    test -S "$gpu_sock" || die "GPU backend did not open $gpu_sock"
    machine+=",gfx-device=apv-gpu-proxy"
    extra_args+=(-global "apv-gpu-proxy.socket=$gpu_sock"
                 -global "apv-gpu-proxy.on-backend-loss=${GPU_BACKEND_LOSS:-stop}")
    case "$console" in
        reims|none) ;;
        gtk)
            display_args=(-display gtk,zoom-to-fit=on)
            export GDK_BACKEND=wayland
            ;;
        *) die "CONSOLE must be reims, none, or gtk" ;;
    esac
elif test "$gfx" = reims && grep -q '^reims-vgpu-mmio options:' <<<"$device_help"; then
    machine+=",gfx-device=reims-vgpu-mmio"
    if test "${REIMS_VGPU_WINDOW:-1}" = 0; then
        # The MMIO device always tries to open its host window and only
        # falls back to the QEMU console (screendump/VNC) when that fails.
        unset WAYLAND_DISPLAY DISPLAY
    elif test -z "${WAYLAND_DISPLAY:-}" && \
            test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wayland-0"; then
        export WAYLAND_DISPLAY=wayland-0
    fi
    case "$console" in
        reims|none) ;;
        gtk)
            display_args=(-display gtk,zoom-to-fit=on)
            export GDK_BACKEND=wayland
            ;;
        *) die "CONSOLE must be reims, none, or gtk" ;;
    esac
fi

# AUDIO=virtio|usb|none: a sound card with a discarding backend (audiodev
# none), so CoreAudio has a default output and playback in the guest and its
# iOS simulators works; nothing is heard. See docs/NOTES.md "Audio (macOS
# guests)". virtio (default): virtio-sound-pci, output stream only
# (AUDIO_OPTS replaces streams=1); AppleVirtIOSound starts only with a QEMU
# that answers empty JACK_INFO/CHMAP_INFO queries (aquarat fork), otherwise
# the guest has no audio device, as with none. usb: usb-audio on the
# machine's xHCI, works with any QEMU but costs ~10x more host CPU while
# playing.
case "${AUDIO:-virtio}" in
    none) ;;
    virtio)
        extra_args+=(-audiodev "none,id=snd0"
                     -device "virtio-sound-pci,audiodev=snd0,${AUDIO_OPTS:-streams=1}")
        ;;
    usb)
        extra_args+=(-audiodev "none,id=snd0"
                     -device "usb-audio,audiodev=snd0${AUDIO_OPTS:+,$AUDIO_OPTS}")
        ;;
    *) die "AUDIO must be virtio, usb, or none" ;;
esac

echo "launching VMApple with KVM (guest ECID loaded from vm.json)"
echo "QEMU: $qemu"
echo "serial: $serial_log"
echo "SSH after guest setup: localhost:$ssh_port"

exec "$qemu" \
    -machine "$machine" \
    -cpu "$cpu_model" \
    -smp "$cpus" \
    -m "$ram" \
    -bios "$booter" \
    -drive "if=pflash,format=raw,file.filename=$guest_dir/aux.img.trimmed,file.locking=off" \
    -drive "if=pflash,format=raw,file.filename=$guest_dir/disk.img,file.locking=off" \
    -drive "if=none,format=raw,file.filename=$guest_dir/aux.img.trimmed,file.locking=off,cache=$disk_cache,id=aux" \
    -device vmapple-virtio-blk-pci,variant=aux,drive=aux,share-rw=on \
    -drive "if=none,format=raw,file.filename=$guest_dir/disk.img,file.locking=off,cache=$disk_cache,id=root" \
    -device vmapple-virtio-blk-pci,variant=root,drive=root,share-rw=on \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:$ssh_bind:$ssh_port-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$guest_mac${NET_DEVICE_OPTS:+,$NET_DEVICE_OPTS}" \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    "${debug_args[@]}" \
    "${extra_args[@]}" \
    "${display_args[@]}" \
    -serial "$serial" \
    -no-reboot

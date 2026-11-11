#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Launch a guest through scripts/launch-kvm.sh, optionally rewriting XNU's
# boot arguments (and the SIP configuration, and one GIC store) at the moment
# the boot loader hands off to the kernel, through QEMU's gdbstub.
#
#   scripts/launch-gui-kvm.sh          (all launch-kvm.sh settings apply)
#
# INJECT [1]     0 = exec launch-kvm.sh directly, nothing else.
#                1 = start QEMU paused with a gdbstub, run the injector at the
#                    hand-off, then let the guest run. Needs gdb.
# With INJECT=1:
#   GDB_PORT [1234]        gdbstub port (on 127.0.0.1)
#   LOG_DIR [logs/]        created; QEMU's logs go there as usual
#   QMP_SOCKET [LOG_DIR/qmp-gui.sock]   the injector reads guest memory
#                          through it (QMP pmemsave)
#   XNU_BOOT_ARGS [-v serial=11 debug=0x14c]   written to boot_args
#                          (set but empty: an empty command line)
#   CSR_CONFIG [0x2]       SIP configuration (u64) for the device tree's
#                          chosen/asmb lp-sip0; empty = leave it alone
#   KVM_MMIO_PATCH [1]     0 = skip the GIC store correction (host kernels
#                          that emulate the store do not need it)
#   VMAPPLE_HANDOFF_PC     hand-off address [0xACA00000]
#   GDB_BIN [gdb]          the GDB to run
#   XNU_INJECTOR [scripts/inject-xnu-kvm.sh]
#
# Exits with QEMU's status. On any failure, and on HUP/INT/TERM, QEMU is sent
# SIGINT and waited for, so no paused guest is left behind.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
launcher="$script_dir/launch-kvm.sh"

die() { echo "error: $*" >&2; exit 1; }

case "${INJECT:-1}" in
    0) exec "$launcher" ;;
    1) ;;
    *) die "INJECT must be 0 or 1, not '${INJECT}'" ;;
esac

gdb_bin="${GDB_BIN:-gdb}"
command -v "$gdb_bin" >/dev/null 2>&1 ||
    die "missing command: $gdb_bin (needed for INJECT=1; install gdb, or set INJECT=0 on a host kernel that emulates the GIC store)"
injector="${XNU_INJECTOR:-$script_dir/inject-xnu-kvm.sh}"
{ test -f "$injector" && test -x "$injector"; } || die "XNU injector not executable: $injector"

gdb_port="${GDB_PORT:-1234}"
[[ "$gdb_port" =~ ^[0-9]+$ ]] || die "GDB_PORT must be a port number (digits only), not '$gdb_port'"
mmio_patch="${KVM_MMIO_PATCH:-1}"
case "$mmio_patch" in 0|1) ;; *) die "KVM_MMIO_PATCH must be 0 or 1, not '$mmio_patch'" ;; esac
boot_args="${XNU_BOOT_ARGS--v serial=11 debug=0x14c}"
csr_config="${CSR_CONFIG-0x2}"

log_dir="${LOG_DIR:-$repo_root/logs}"
mkdir -p "$log_dir"
qmp_socket="${QMP_SOCKET:-$log_dir/qmp-gui.sock}"
# A socket left by an earlier run would look like QEMU's: remove it first.
if test -S "$qmp_socket"; then
    rm -f -- "$qmp_socket"
elif test -e "$qmp_socket" || test -L "$qmp_socket"; then
    die "$qmp_socket exists and is not a socket; not removing it"
fi

qemu_pid=
# shellcheck disable=SC2329  # invoked from the EXIT trap
stop_qemu() {
    local i
    test -n "$qemu_pid" || return 0
    if kill -0 "$qemu_pid" 2>/dev/null; then
        echo "launch-gui-kvm: stopping QEMU (pid $qemu_pid)" >&2
        kill -INT "$qemu_pid" 2>/dev/null || true
        # QEMU exits on SIGINT within moments; never leave it behind.
        for ((i = 0; i < 300; i++)); do
            kill -0 "$qemu_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$qemu_pid" 2>/dev/null; then
            echo "launch-gui-kvm: QEMU ignored SIGINT for 30 s; killing it" >&2
            kill -KILL "$qemu_pid" 2>/dev/null || true
        fi
    fi
    wait "$qemu_pid" 2>/dev/null || true
    qemu_pid=
}
trap stop_qemu EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Background jobs of a script start with SIGINT ignored, and QEMU would
# inherit that; restore the default so SIGINT reaches QEMU before it has
# installed its own handler, too. launch-kvm.sh execs QEMU, so this PID
# becomes QEMU's.
(
    trap - INT
    export PAUSE_AT_START=on GDB_PORT="$gdb_port" QMP_SOCKET="$qmp_socket" LOG_DIR="$log_dir"
    exec "$launcher"
) &
qemu_pid=$!

for ((i = 0; i < 300; i++)); do
    test -S "$qmp_socket" && break
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        status=0
        wait "$qemu_pid" || status=$?
        qemu_pid=
        die "QEMU exited (status $status) before opening its QMP socket"
    fi
    sleep 0.1
done
test -S "$qmp_socket" || die "QEMU did not open its QMP socket $qmp_socket within 30 s"

echo "launch-gui-kvm: QEMU paused (pid $qemu_pid); hand-off injection through 127.0.0.1:$gdb_port"
"$injector" --port "$gdb_port" --boot-args "$boot_args" --csr "$csr_config" \
    --mmio-patch "$mmio_patch" --qmp "$qmp_socket" ||
    die "XNU hand-off injection failed; stopping the guest"

status=0
wait "$qemu_pid" || status=$?
qemu_pid=
exit "$status"

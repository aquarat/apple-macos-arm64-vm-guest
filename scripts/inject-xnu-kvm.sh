#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# XNU hand-off injector: attach GDB to a paused vmapple QEMU's gdbstub, stop
# at the boot loader's hand-off to XNU (the second arrival at
# VMAPPLE_HANDOFF_PC, hardware breakpoint), edit boot_args, the device tree
# and one GIC store in guest memory, then detach so the guest runs on.
# scripts/launch-gui-kvm.sh runs it (INJECT=1); it can also be run by hand
# against a QEMU started with GDB_PORT=<port> PAUSE_AT_START=on.
#
#   scripts/inject-xnu-kvm.sh [--port N] [--boot-args S] [--csr VALUE]
#                             [--mmio-patch 0|1] [--qmp SOCKET]
#
# Defaults come from the environment: GDB_PORT [1234], XNU_BOOT_ARGS
# [-v serial=11 debug=0x14c], CSR_CONFIG [0x2; empty = leave SIP alone],
# KVM_MMIO_PATCH [1], QMP_SOCKET [none: read memory through the gdbstub,
# slowly]. Also: VMAPPLE_HANDOFF_PC [0xACA00000], GDB_BIN [gdb].
#
# What it changes (details in scripts/lib/xnu_handoff.py):
#   - boot_args.CommandLine := the boot arguments (< 608 bytes, no NUL);
#   - device tree /chosen/asmb lp-sip0 := CSR value as u64 (lp-stng is
#     renamed to lp-sip0 when lp-sip0 is absent);
#   - the GIC setup's pre-indexed store, which older host kernels cannot
#     emulate, is rewritten as two plain stores (KVM_MMIO_PATCH=1).
# Prints one line per action; exits non-zero with "error: ..." on any problem,
# leaving QEMU for the caller to stop.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/lib/xnu_handoff.py"

die() { echo "error: $*" >&2; exit 1; }
usage() {
    echo "usage: $0 [--port N] [--boot-args S] [--csr VALUE] [--mmio-patch 0|1] [--qmp SOCKET]"
}

port="${GDB_PORT:-1234}"
boot_args="${XNU_BOOT_ARGS--v serial=11 debug=0x14c}"
csr="${CSR_CONFIG-0x2}"
mmio_patch="${KVM_MMIO_PATCH:-1}"
qmp="${QMP_SOCKET:-}"

while (( $# > 0 )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --port|--boot-args|--csr|--mmio-patch|--qmp)
            (( $# >= 2 )) || { usage >&2; die "$1 needs a value"; }
            case "$1" in
                --port) port="$2" ;;
                --boot-args) boot_args="$2" ;;
                --csr) csr="$2" ;;
                --mmio-patch) mmio_patch="$2" ;;
                --qmp) qmp="$2" ;;
            esac
            shift 2
            ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ "$port" =~ ^[0-9]+$ ]] || die "GDB port must be digits only, not '$port'"
case "$mmio_patch" in 0|1) ;; *) die "KVM_MMIO_PATCH must be 0 or 1, not '$mmio_patch'" ;; esac
if test -n "$csr" && ! [[ "$csr" =~ ^(0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+|[0-9]+)$ ]]; then
    die "CSR_CONFIG must be an integer (0x.., 0o.., 0b.. or decimal), not '$csr'"
fi
if test -n "${VMAPPLE_HANDOFF_PC:-}" &&
   ! [[ "$VMAPPLE_HANDOFF_PC" =~ ^(0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+|[0-9]+)$ ]]; then
    die "VMAPPLE_HANDOFF_PC must be an integer (0x.., 0o.., 0b.. or decimal), not '$VMAPPLE_HANDOFF_PC'"
fi
boot_args_len="$(printf '%s' "$boot_args" | wc -c)"
(( boot_args_len < 608 )) || die "XNU_BOOT_ARGS is $boot_args_len bytes; it must be shorter than 608"
if test -n "$qmp" && ! test -S "$qmp"; then
    die "QMP socket not found: $qmp"
fi
gdb_bin="${GDB_BIN:-gdb}"
command -v "$gdb_bin" >/dev/null 2>&1 || die "missing command: $gdb_bin"
test -f "$helper" || die "missing $helper"

status_file="$(mktemp "${TMPDIR:-/tmp}/xnu-handoff-status.XXXXXX")"
trap 'rm -f -- "$status_file"' EXIT

rc=0
XNU_HANDOFF_GDB_PORT="$port" XNU_HANDOFF_BOOT_ARGS="$boot_args" \
XNU_HANDOFF_CSR="$csr" XNU_HANDOFF_MMIO_PATCH="$mmio_patch" \
XNU_HANDOFF_QMP="$qmp" XNU_HANDOFF_STATUS="$status_file" \
    "$gdb_bin" -q -nx -batch -x "$helper" < /dev/null || rc=$?

if test "$(cat "$status_file")" != ok; then
    die "hand-off injection did not complete (gdb exit status $rc)"
fi
echo "xnu-handoff: done"

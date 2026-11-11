#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Check that this host can run a macOS guest with KVM in QEMU's vmapple
# machine: an aarch64 host, read/write access to /dev/kvm, and a QEMU (chosen
# like scripts/launch-kvm.sh does: QEMU_BIN, else build/qemu-fleet and the
# older build directories) that has the vmapple machine.
#
#   scripts/check-host.sh
#
# Prints a short summary and exits 0 when everything is in place; otherwise
# prints "error: ..." on stderr and exits non-zero. launch-kvm.sh runs it
# before every launch and discards its stdout.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

die() { echo "error: $*" >&2; exit 1; }

# shellcheck source=lib/qemu-select.sh
. "$script_dir/lib/qemu-select.sh"

arch="$(uname -m)"
test "$arch" = aarch64 || die "this host is $arch; vmapple guests need an aarch64 (Apple Silicon) host"

if ! { test -r /dev/kvm && test -w /dev/kvm; }; then
    die "/dev/kvm is not readable and writable by $(id -un) (KVM missing, or not in the kvm group?)"
fi

qemu="$(select_qemu "$repo_root")"
if ! { test -f "$qemu" && test -x "$qemu"; }; then
    die "no executable QEMU at $qemu (build one with scripts/build-qemu.sh, or set QEMU_BIN)"
fi

machines="$("$qemu" -machine help 2>&1)" || die "$qemu -machine help failed: $machines"
grep -q '^vmapple ' <<<"$machines" || die "$qemu has no vmapple machine (not a vmapple-capable QEMU build)"

echo "architecture: $arch"
echo "kernel: $(uname -r)"
echo "KVM: /dev/kvm accessible"
echo "QEMU: $qemu"
echo "host check passed"

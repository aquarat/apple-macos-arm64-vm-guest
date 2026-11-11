# shellcheck shell=bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Shared by scripts/launch-kvm.sh and scripts/check-host.sh (sourced, not run):
# which qemu-system-aarch64 to use.
#
#   select_qemu <repo-root>     prints the chosen path on stdout
#
# Order: $QEMU_BIN when set and non-empty (taken as given, even if it does
# not exist, so the caller's check names it); else the first executable of
# the known build directories, newest flow first; else the legacy build path,
# which the caller's check then reports as missing.

select_qemu() {
    local root="$1" candidate
    if test -n "${QEMU_BIN:-}"; then
        printf '%s\n' "$QEMU_BIN"
        return 0
    fi
    for candidate in \
        "$root/build/qemu-fleet/vendor/qemu/build/qemu-system-aarch64" \
        "$root/build/reims-linux-product/vendor/qemu/build/qemu-system-aarch64" \
        "$root/build/reims-linux/vendor/qemu/build/qemu-system-aarch64"; do
        if test -f "$candidate" && test -x "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '%s\n' "$root/build/experiment-macOS-arm64-on-linux-x86/build/qemu-system-aarch64"
}

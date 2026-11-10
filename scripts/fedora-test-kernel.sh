#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install a locally built Fedora Asahi kernel beside the default one without
# changing the default boot entry, and select it for exactly one boot.
#
#   scripts/fedora-test-kernel.sh install <rpm-dir> <version-release.arch>
#   scripts/fedora-test-kernel.sh boot-once <kernel-release>   # e.g. 7.1.13-401.asahi.vmapple1.fc44.aarch64+16k
#   scripts/fedora-test-kernel.sh status
#
# Fedora's /etc/sysconfig/kernel has UPDATEDEFAULT=yes, so a plain install
# would make the new kernel the default. This script records the default
# before installing and restores it afterwards. boot-once uses grub2-reboot,
# so a hang (with the systemd hardware watchdog armed) or a power cycle falls
# back to the unchanged default.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

status() {
    echo "running:  $(uname -r)"
    echo "default:  $(sudo grubby --default-kernel)"
    sudo grub2-editenv list | grep -E '^(saved_entry|next_entry)=' || true
    df -h /boot | tail -1
}

case "${1:-}" in
install)
    rpm_dir="${2:?rpm dir}"; vr="${3:?version-release.arch}"
    pkgs=()
    for p in kernel-16k-core kernel-16k-modules-core kernel-16k-modules kernel-16k; do
        f="$rpm_dir/$p-$vr.rpm"
        test -f "$f" || die "missing $f"
        pkgs+=("$f")
    done
    before="$(sudo grubby --default-kernel)"
    echo "default before install: $before"
    sudo cp -a /etc/sysconfig/kernel /etc/sysconfig/kernel.pre-test-kernel
    trap 'sudo cp -a /etc/sysconfig/kernel.pre-test-kernel /etc/sysconfig/kernel' EXIT
    sudo sed -i 's/^UPDATEDEFAULT=yes/UPDATEDEFAULT=no/' /etc/sysconfig/kernel
    # installonly_limit=0: never let dnf remove an older installed kernel to
    # make room for the test kernel.
    sudo dnf install -y --setopt=install_weak_deps=False \
        --setopt=installonly_limit=0 "${pkgs[@]}"
    after="$(sudo grubby --default-kernel)"
    if test "$after" != "$before"; then
        echo "default changed to $after; restoring $before"
        sudo grubby --set-default "$before"
    fi
    status
    ;;
boot-once)
    rel="${2:?kernel release}"
    test -f "/boot/vmlinuz-$rel" || die "no /boot/vmlinuz-$rel"
    id="$(sudo grubby --info="/boot/vmlinuz-$rel" | sed -n 's/^id="\(.*\)"/\1/p')"
    test -n "$id" || die "no BLS entry for $rel"
    sudo grub2-reboot "$id"
    status
    echo "next boot only: $id"
    ;;
status) status ;;
*) die "usage: $0 install <rpm-dir> <vr.arch> | boot-once <release> | status" ;;
esac

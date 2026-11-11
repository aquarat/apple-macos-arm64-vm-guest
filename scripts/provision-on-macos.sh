#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Restore a macOS IPSW into a new guest bundle with macosvm
# (https://github.com/s-u/macosvm). Runs on native macOS (Apple Silicon);
# images/host/macos-restore.sh is the usual caller.
#
#   IPSW=<restore.ipsw> scripts/provision-on-macos.sh
#   scripts/provision-on-macos.sh <restore.ipsw>
#
# Environment (defaults in brackets): GUEST_DIR [artifacts/guest],
# DISK_SIZE [64g], CPUS [4], RAM [8g], GUEST_MAC [52:54:00:76:61:70].
# Everything else in the environment reaches macosvm as is (e.g. the patched
# macosvm's MACOSVM_HWMODEL_B64).
#
# Creates GUEST_DIR/disk.img, aux.img and vm.json (macosvm), then
# aux.img.trimmed: aux.img without its first 16 KiB, the form QEMU's vmapple
# machine takes. Never overwrites an existing disk.img. Asks for
# confirmation on stdin first (y/yes; anything else cancels).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

die() { echo "error: $*" >&2; exit 1; }
usage() {
    echo "usage: $0 <restore.ipsw>   (or IPSW=<restore.ipsw> $0)"
}

# One restore image is pinned: the Ventura build the project was proven with.
known_ipsw_name=UniversalMac_13.6_22G120_Restore.ipsw
known_ipsw_sha1=a1675f2c8412122a5e796981571b0269a966708e
aux_header_bytes=16384

os="$(uname -s)"
test "$os" = Darwin || die "this runs on native macOS only (uname -s: $os); restore on a Mac, then copy the bundle"
command -v macosvm >/dev/null 2>&1 || die "macosvm not found on PATH (install it: brew install macosvm)"

ipsw="${IPSW:-${1:-}}"
if test -z "$ipsw"; then
    usage >&2
    die "no IPSW given"
fi
test -f "$ipsw" || die "IPSW not found: $ipsw"

guest_dir="${GUEST_DIR:-$repo_root/artifacts/guest}"
disk_size="${DISK_SIZE:-64g}"
cpus="${CPUS:-4}"
ram="${RAM:-8g}"
guest_mac="${GUEST_MAC:-52:54:00:76:61:70}"

if test -e "$guest_dir/disk.img" || test -L "$guest_dir/disk.img"; then
    die "$guest_dir/disk.img already exists; not overwriting it (choose another GUEST_DIR)"
fi

if test "$(basename "$ipsw")" = "$known_ipsw_name"; then
    command -v shasum >/dev/null 2>&1 || die "missing command: shasum (checks the IPSW)"
    echo "checking the SHA-1 of $ipsw ..."
    actual_sha1="$(shasum -a 1 "$ipsw" | awk '{print $1}')"
    if test "$actual_sha1" != "$known_ipsw_sha1"; then
        die "SHA-1 mismatch for $ipsw: got $actual_sha1, expected $known_ipsw_sha1"
    fi
    echo "SHA-1 ok: $actual_sha1"
fi

ipsw_bytes="$(wc -c < "$ipsw" | tr -d ' ')"
ipsw_gib="$(awk -v b="$ipsw_bytes" 'BEGIN { printf "%.1f", b / 1073741824 }')"
cat <<EOF
About to restore a macOS guest with macosvm:
  IPSW:        $ipsw ($ipsw_bytes bytes, ${ipsw_gib} GiB)
  disk size:   $disk_size (sparse)
  CPUs, RAM:   $cpus, $ram
  MAC address: $guest_mac
  destination: $guest_dir
  creates:     $guest_dir/disk.img
               $guest_dir/aux.img
               $guest_dir/vm.json
               (then $guest_dir/aux.img.trimmed for QEMU)
EOF
printf 'Continue? [y/N] '
answer=
read -r answer || true
test -t 0 || echo    # piped answer: end the prompt's line
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "cancelled"; exit 0 ;;
esac

mkdir -p "$guest_dir"
macosvm \
    --disk "$guest_dir/disk.img,size=$disk_size" \
    --aux "$guest_dir/aux.img" \
    --restore "$ipsw" \
    --net nat \
    --mac "$guest_mac" \
    -c "$cpus" \
    -r "$ram" \
    "$guest_dir/vm.json"

test -f "$guest_dir/vm.json" || die "macosvm finished but $guest_dir/vm.json is missing"
test -f "$guest_dir/aux.img" || die "macosvm finished but $guest_dir/aux.img is missing"
aux_bytes="$(wc -c < "$guest_dir/aux.img" | tr -d ' ')"
(( aux_bytes > aux_header_bytes )) ||
    die "$guest_dir/aux.img is only $aux_bytes bytes; expected more than its $aux_header_bytes-byte header"
# QEMU's vmapple machine takes the auxiliary storage without its header.
tail -c +"$((aux_header_bytes + 1))" "$guest_dir/aux.img" > "$guest_dir/aux.img.trimmed"

echo "guest bundle ready: $guest_dir"
echo "  disk.img, aux.img, aux.img.trimmed, vm.json (vm.json is the VM's identity: keep it private)"
echo "next: copy $guest_dir to the Asahi host's checkout as artifacts/guest (keep disk.img sparse)"

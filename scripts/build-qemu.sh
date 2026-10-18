#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build qemu-system-aarch64 (vmapple + KVM + Reims GPU) from the aquarat
# forks; no patch files are applied.
#
#   scripts/build-qemu.sh [OUTDIR]               Reims in process (default)
#   MODE=oop scripts/build-qemu.sh [OUTDIR]      Reims out of process
#
# In process (OUTDIR default build/qemu-fleet): QEMU is Reims' vendor/qemu
# submodule, i.e. aquarat/qemu-reims-vgpu at the commit Reims pins (the last one
# with the in-process shims), and links Reims as a Rust staticlib.
#
# Out of process (MODE=oop, OUTDIR default build/qemu-oop): QEMU is built on its
# own from QEMU_URL/QEMU_REF and contains no Reims code; Reims is built as the
# reims-vgpu-backend program from REIMS_URL/REIMS_REF. Launch with
# QEMU_BIN=OUTDIR/qemu/build/qemu-system-aarch64 and
# GPU_BACKEND_BIN=OUTDIR/reims/target/release/reims-vgpu-backend.
#
# Environment: REIMS_URL (default https://github.com/aquarat/reims-vgpu.git),
# REIMS_REF (default master), QEMU_URL (in process: override the vendor/qemu
# source, e.g. a local repository with unpushed commits; out of process: the
# QEMU repository, default https://github.com/aquarat/qemu-reims-vgpu.git),
# QEMU_REF (out of process only, default master). An existing OUTDIR is updated
# in place (fetch, checkout, incremental build).
# Needs: git cargo ninja meson gcc, and the -devel packages listed in
# docs/NOTES.md (glib2 pixman gtk3 vulkan-loader libslirp libfdt gnutls nettle ...).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${MODE:-inprocess}"
url="${REIMS_URL:-https://github.com/aquarat/reims-vgpu.git}"
ref="${REIMS_REF:-master}"
die() { echo "error: $*" >&2; exit 1; }
for c in git cargo ninja meson cc; do command -v "$c" >/dev/null || die "missing $c"; done

# fetch_checkout <dir> <url> <ref>: clone once, then detach at the fetched ref.
# Fetch the ref in both cases: `checkout --detach <branch>` on a fresh clone
# fails for any branch but the default (git tries to create a tracking branch).
fetch_checkout() {
    test -d "$1/.git" || git clone -q "$2" "$1"
    git -C "$1" fetch -q "$2" "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}

if test "$mode" = oop; then
    out="${1:-$repo_root/build/qemu-oop}"
    qurl="${QEMU_URL:-https://github.com/aquarat/qemu-reims-vgpu.git}"
    qref="${QEMU_REF:-master}"
    mkdir -p "$out"
    fetch_checkout "$out/reims" "$url" "$ref"
    fetch_checkout "$out/qemu" "$qurl" "$qref"
    (
        cd "$out/reims"
        cargo build --release -p reims-vgpu-backend > build.log 2>&1 ||
            { grep -E "^error" -A5 build.log | head -20; die "backend build failed (see $out/reims/build.log)"; }
    )
    (
        cd "$out/qemu"
        if ! test -f build/build.ninja; then
            ./configure --target-list=aarch64-softmmu --enable-kvm --enable-gnutls \
                --enable-gtk --disable-docs --disable-tools \
                > configure.log 2>&1 || { tail -20 configure.log; die "configure failed"; }
        fi
        ninja -C build qemu-system-aarch64 pc-bios/keymaps/en-us > build.log 2>&1 ||
            { grep -E "error|FAILED" build.log | head -20; die "build failed (see $out/qemu/build.log)"; }
    )
    bin="$out/qemu/build/qemu-system-aarch64"
    backend="$out/reims/target/release/reims-vgpu-backend"
    {
        echo "mode     out of process"
        echo "reims    $url $(git -C "$out/reims" rev-parse HEAD)"
        echo "qemu     $qurl $(git -C "$out/qemu" rev-parse HEAD)"
        echo "binary   $(sha256sum "$bin" | cut -d' ' -f1)"
        echo "backend  $(sha256sum "$backend" | cut -d' ' -f1)"
        echo "built    $(date -Is) on $(hostname -s)"
    } | tee "$out/BUILD-MANIFEST"
    echo "QEMU_BIN=$bin"
    echo "GPU_BACKEND_BIN=$backend"
    exit 0
fi
test "$mode" = inprocess || die "MODE must be inprocess or oop"
out="${1:-$repo_root/build/qemu-fleet}"

fetch_checkout "$out" "$url" "$ref"
if test -n "${QEMU_URL:-}"; then
    # Build unpushed QEMU commits (e.g. from scripts/sync-upstream.sh).
    git -C "$out" submodule init -q vendor/qemu
    git -C "$out" config submodule.vendor/qemu.url "$QEMU_URL"
else
    git -C "$out" submodule sync -q vendor/qemu
fi
git -C "$out" submodule update -q --init vendor/qemu

q="$out/vendor/qemu"
(
    cd "$q"
    if ! test -f build/build.ninja; then
        ./configure --target-list=aarch64-softmmu --enable-kvm --enable-gnutls \
            --enable-gtk --disable-docs --disable-tools -Dreims_vgpu_backend=vulkan \
            > configure.log 2>&1 || { tail -20 configure.log; die "configure failed"; }
    fi
    ninja -C build qemu-system-aarch64 pc-bios/keymaps/en-us > build.log 2>&1 ||
        { grep -E "error|FAILED" build.log | head -20; die "build failed (see $q/build.log)"; }
)
bin="$q/build/qemu-system-aarch64"
{
    echo "reims    $url $(git -C "$out" rev-parse HEAD)"
    echo "qemu     $(git -C "$q" remote get-url origin) $(git -C "$q" rev-parse HEAD)"
    echo "binary   $(sha256sum "$bin" | cut -d' ' -f1)"
    echo "built    $(date -Is) on $(hostname -s)"
} | tee "$out/BUILD-MANIFEST"
echo "QEMU_BIN=$bin"

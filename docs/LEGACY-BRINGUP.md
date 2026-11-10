# Legacy: the first bring-up (M2 Pro, Fedora 42, GUI window)

This is the flow that first booted macOS under KVM on Asahi Linux. It is
kept for reference and for the history of the patches. **New hosts should
follow the current flow in the [README](../README.md) and
[IMAGES.md](IMAGES.md)**: Fedora Asahi Remix 44, the 7.1.13 kernel patches,
`scripts/build-qemu.sh` and headless golden images.

What differs from the current flow:

| Layer | Legacy flow (this page) | Current flow |
| --- | --- | --- |
| Host | M2 Pro, Fedora 42, kernel `6.19.14-vmapple2` | M1 Max / M1 Ultra, Fedora Asahi Remix 44, kernel-16k 7.1.13 |
| Host kernel | steelbrain's [`linux-6.19-vmapple-pac-vmkey.patch`](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64/blob/657bb24/patches/linux-6.19-vmapple-pac-vmkey.patch), built by hand | `patches/linux-7.1.13-*` (PAuth context plus in-KVM emulation of the GIC store), built by `scripts/build-host-kernel.sh` |
| XNU hand-off | GDB rewrites XNU's GIC store at hand-off (`scripts/inject-xnu-kvm.gdb`) | Emulated in KVM; `INJECT=0`, no GDB (GDB is used only for the single-user account step) |
| QEMU / Reims | Reims pinned at `2844274c`, with `patches/reims-*.patch`, built by `scripts/build-gui-qemu.sh` | The aquarat Reims and QEMU forks, built by `scripts/build-qemu.sh`; no patch files |
| Renderer | Mesa llvmpipe, in a host window | Honeykrisp (patched Mesa) on GPU slots, `GFX=none` elsewhere, headless |
| Guest | macOS 13.6 Ventura, provisioned by hand on macOS | macOS 13.6 and 26.4 golden image chains ([IMAGES.md](IMAGES.md)) |

The current flow has been run on M1 Max and M1 Ultra hosts. The M2 Pro ran
only this legacy flow.

## What worked

The known-good configuration booted macOS Ventura 13.6 (22G120) to the normal
graphical Setup Assistant on an M2 Pro host running Fedora Asahi Remix:

- KVM acceleration with eight active guest CPUs
- normal `launchd`, `WindowServer`, and `loginwindow` userspace
- `AppleParavirtGPU` and `AppleParavirtDisplay`
- a live 1920x1080 Reims/Vulkan window
- persistent serial and QMP logs
- user-mode networking with optional SSH forwarding on `localhost:2222`

Rendering was verified with Mesa llvmpipe because the host kernel used for
that run did not include the Asahi DRM driver. A summary of the
investigation, including failed approaches, is in [NOTES.md](NOTES.md).

## Why patches were needed

| Layer | Problem | What was changed |
| --- | --- | --- |
| Linux KVM | Apple's pointer-authentication VM key, `APCTL`, and `KERNKEY` state is not part of the normal ARM KVM context | Saves/restores the Apple registers and exposes them through KVM's one-register API |
| QEMU `vmapple` | The machine was built around TCG/HVF assumptions | Enables KVM, wires the GIC/PMU timers, forwards Apple's private PAuth HVC service to QEMU, implements that service, and pins PSCI to 1.1 for Ventura |
| XNU handoff | KVM cannot emulate one pre-indexed GIC MMIO store because the stage-2 abort lacks a valid instruction syndrome | The launcher pauses at handoff and uses GDB to rewrite that exact instruction sequence in guest RAM; the guest disk is not modified |
| Reims | Linux guest-memory mapping and llvmpipe capability reporting differed from the macOS host path | Adds direct mappings for contiguous QEMU RAM and avoids the native-FP16 shader path on CPU Vulkan devices |

The current host kernel replaces the GDB rewrite with emulation in KVM
(`patches/linux-7.1.13-kvm-nisv-ldst.patch`, see NOTES.md, "Host kernel"),
and the QEMU and Reims changes now live in the forks.

The relevant files are:

- steelbrain's [`linux-6.19-vmapple-pac-vmkey.patch`](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64/blob/657bb24/patches/linux-6.19-vmapple-pac-vmkey.patch) (not in this repository: it has no licence)
- [`patches/reims-qemu-linux-arm64.patch`](../patches/reims-qemu-linux-arm64.patch)
- [`patches/reims-rust-linux-arm64.patch`](../patches/reims-rust-linux-arm64.patch)
- [`scripts/inject-xnu-kvm.gdb`](../scripts/inject-xnu-kvm.gdb)

[`patches/vmapple-usb-chardev.patch`](../patches/vmapple-usb-chardev.patch) and
the USB/IP scripts belong to the separate Linux restore experiment (below).
They are not needed when starting with a VM provisioned on macOS.

## Requirements (legacy flow)

- an Apple Silicon Mac running Asahi Linux with `/dev/kvm` available
- a matching Fedora/Asahi 16 KiB kernel source tree
- the kernel patch in this repository, built and booted as a separate kernel
- GDB, Git, a C toolchain, Cargo, Ninja, GTK 3 development files, and Vulkan
  development files
- temporary access to macOS for Apple firmware and VM provisioning
- roughly 20 GiB for an Apple restore image, 64 GiB apparent space for the
  sparse guest disk, and several GiB for builds

The proven host was Fedora 42 on an M2 Pro with kernel `6.19.14-vmapple2`.

## 1. Obtain AVPBooter from macOS

`AVPBooter.vmapple2.bin` is supplied by macOS as part of
Virtualization.framework. On a Mac, copy it out with:

```sh
cp /System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin .
shasum -a 256 AVPBooter.vmapple2.bin
```

Move it to the Asahi host and keep it under the ignored `artifacts/` directory:

```sh
mkdir -p artifacts/firmware
mv /path/to/AVPBooter.vmapple2.bin artifacts/firmware/
```

The successful run used `mBoot-18000.121.3` (304,352 bytes, SHA-256
`513ca3fbb2cd5accb0a6da96a5e476d593ebae403d7edb33aebca88f505dac61`).
Do not publish this file: it is Apple-provided firmware and is intentionally
excluded by `.gitignore`.

## 2. Provision the guest on macOS

Install [macosvm](https://github.com/s-u/macosvm), clone this repository on the
macOS machine, and supply a legitimately obtained UniversalMac restore IPSW:

```sh
brew install macosvm
IPSW=/path/to/UniversalMac_13.6_22G120_Restore.ipsw \
  scripts/provision-on-macos.sh
```

The script creates this private bundle:

```text
artifacts/guest/
├── aux.img
├── aux.img.trimmed
├── disk.img
└── vm.json
```

Copy the bundle to the same location on the Asahi host. Preserve the sparse
disk while copying; for example, use `rsync --sparse`. `vm.json` contains the
VM's machine identity, and the images contain an installed copy of macOS, so
none of these files should be committed or shared.

The known Ventura IPSW is
`UniversalMac_13.6_22G120_Restore.ipsw`, SHA-1
`a1675f2c8412122a5e796981571b0269a966708e`. Apple firmware and restore-version
compatibility can change; start with the verified versions before trying a
newer combination. (The current flow does this step with
`images/host/macos-restore.sh`, which wraps `provision-on-macos.sh`.)

## 3. Build and boot the patched Asahi kernel

Apply the kernel patch after preparing the matching Fedora Asahi
`6.19.14-400.asahi.fc42` source tree. The patch is steelbrain's, from his
repository at `657bb24`; it has no licence and is not in this one:

```sh
curl -LO https://raw.githubusercontent.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64/657bb24/patches/linux-6.19-vmapple-pac-vmkey.patch
patch -d /path/to/linux-tree -p1 < linux-6.19-vmapple-pac-vmkey.patch
```

Use the installed 16 KiB kernel configuration, build `Image`, `modules`,
`vmlinuz.efi`, and `dtbs`, then install the result alongside the stock kernel
with a distinct `LOCALVERSION` such as `-vmapple2`. Keep the stock kernel as
the default and select the patched kernel for one boot first.

This patch is tied to that kernel revision; do not apply it blindly to
another release. For Fedora Asahi 7.1.x kernels use
`scripts/build-host-kernel.sh`, which applies the `patches/linux-7.1.13-*`
patches to the host's own base SRPM.

After booting the patched kernel:

```sh
uname -r
test -r /dev/kvm && test -w /dev/kvm
```

## 4. Build the patched Reims/QEMU

Clone the pinned Reims revision next to this repository and initialize its QEMU
submodule:

```sh
git clone https://github.com/steelbrain-bot/reims-vgpu.git ../reims-vgpu
git -C ../reims-vgpu checkout 2844274c34baa1043d37995f5b1a9f1d265eae03
git -C ../reims-vgpu submodule update --init vendor/qemu
git -C ../reims-vgpu/vendor/qemu rev-parse HEAD
# expected: e17ddb98f71df5697daf2f830587f672a8f4f5a7

CONFIRM=1 scripts/build-gui-qemu.sh
```

The build script verifies both revisions, copies the source under ignored
`build/`, applies the QEMU and Reims patches, and produces:

```text
build/reims-linux-product/vendor/qemu/build/qemu-system-aarch64
```

Verify the complete host side:

```sh
scripts/check-host.sh
```

`check-host.sh` and `launch-kvm.sh` prefer `build/qemu-fleet` (the current
`build-qemu.sh` output) when it exists; set `QEMU_BIN` to choose a binary.

## 5. Launch macOS

With the firmware and guest bundle in place:

```sh
AVPBOOTER="$PWD/artifacts/firmware/AVPBooter.vmapple2.bin" \
GUEST_DIR="$PWD/artifacts/guest" \
  scripts/launch-gui-kvm.sh
```

QEMU starts paused. The wrapper injects verbose boot arguments, applies the
verified XNU GIC instruction correction, detaches GDB, and leaves QEMU in the
foreground. Press Ctrl-C to stop it cleanly. Serial and QMP logs are written
under ignored `logs/`.

Useful overrides:

```sh
CPUS=4 RAM=8G ...                 # guest resources
SSH_PORT=2223 ...                 # host-side SSH forwarding
CONSOLE=gtk ...                   # also show QEMU's fallback GTK console
CONSOLE=none ...                  # suppress every fallback console
XNU_BOOT_ARGS='-v serial=11 debug=0x14c' ...
```

The normal display path is the native Reims window, so the default QEMU display
is `none`. `scripts/launch-kvm.sh` is the lower-level launcher when the GDB
handoff wrapper is not wanted (`INJECT=0` makes `launch-gui-kvm.sh` call it
directly; that needs the 7.1.13 kernel's GIC store emulation).

## Linux restore experiment (unfinished)

The repository also contains an unfinished attempt to provision directly from
Asahi Linux. `scripts/launch-dfu.sh` exposes AVPBooter's virtual DFU device,
`scripts/vmapple-usbip.py` bridges it to Linux `vhci-hcd`, and
`scripts/probe-vmapple-usb.py` exercises the transport. The work reached real
DFU transfers but did not produce a bootable guest. See
[NOTES.md](NOTES.md#linux-restore-experiment-unfinished) before continuing
that path. Provisioning still needs macOS.

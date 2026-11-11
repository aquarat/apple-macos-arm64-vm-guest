# Licensing

This project is licensed under the GNU General Public License, version 2 or
(at your option) any later version (`GPL-2.0-or-later`); the full text is in
[LICENSE](LICENSE). The exceptions below are files that are not this
project's own work, or that patch other projects.

## Work by the original author

This repository started as a fork of
[steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64)
by Anees Iqbal (steelbrain). That repository had no licence. On 2026-11-11
he released the patches in it into the public domain
([comment](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64/issues/1#issuecomment-6789795685)). His statement names the patches only, so his other
files here remain his, all rights reserved: they are included as published
upstream, with credit, and this project grants no licence to them.

His work is in these files, taken unchanged from the bootstrap commit
(`657bb24`).

Patches, public domain since 2026-11-11:

- `patches/reims-qemu-linux-arm64.patch`
- `patches/reims-rust-linux-arm64.patch`
- `patches/vmapple-usb-chardev.patch`

Scripts, not licensed:

- `scripts/launch-dfu.sh`
- `scripts/probe-vmapple-usb.py`
- `scripts/restore-info.sh`
- `scripts/vmapple-usbip.py`

This file contains his work together with later changes made in this
project. Only the later changes are under `GPL-2.0-or-later`:

- `scripts/build-gui-qemu.sh`

All five belong to the legacy bring-up flow
([docs/LEGACY-BRINGUP.md](docs/LEGACY-BRINGUP.md)); the current flow does
not use them. If the original author asks, they will be rewritten or
removed.

The current flow used to contain more of his work. On 2026-11-11 that was
replaced by an independent rewrite under `GPL-2.0-or-later`, written from a
functional specification by someone who had not seen his files
([provenance](docs/SCRIPTS-PROVENANCE.md)):
`scripts/launch-kvm.sh`, `scripts/launch-gui-kvm.sh`,
`scripts/check-host.sh`, `scripts/extract-ecid.py`,
`scripts/provision-on-macos.sh`, `scripts/inject-xnu-kvm.sh` and
`scripts/lib/`, together with the passages of `AGENTS.md` and `README.md`
that were his. `scripts/inject-xnu-kvm.gdb` and
`scripts/apple_device_tree.py` were removed; `scripts/lib/xnu_handoff.py`
does their job.

His Linux 6.19 PAuth patch (`patches/linux-6.19-vmapple-pac-vmkey.patch`)
and its rebase to 7.1.13 are no longer in this repository (the 6.19 patch
is public domain now too). The legacy flow points to his copy upstream. `patches/linux-7.1.13-vmapple-pac-vmkey.patch`
is now an independent implementation by this project, written clean-room
style from m1n1's register definitions and a functional specification
([provenance](https://github.com/aquarat/apple-silicon-kernel-plus/blob/main/docs/kvm-pauth-provenance.md)).
It is offered under Linux's licence (below).

## Patches to other projects

A patch is a change to another project, so it is offered under that
project's licence:

| Patch | Licence |
| --- | --- |
| `patches/linux-7.1.13-kvm-nisv-ldst.patch`, `patches/linux-7.1.13-vmapple-pac-vmkey.patch` | GPL-2.0 (Linux) |
| `patches/qemu-*.patch` | GPL-2.0-or-later (QEMU) |
| `patches/mesa/*.patch` | MIT (Mesa) |
| `patches/macosvm-hwmodel-override.patch` | macosvm's licence |

## Dependencies

The QEMU and Reims changes live in their own forks, each under its
upstream's licence:
[aquarat/qemu-reims-vgpu](https://github.com/aquarat/qemu-reims-vgpu)
(GPL-2.0-or-later),
[aquarat/reims-vgpu](https://github.com/aquarat/reims-vgpu) and
[aquarat/metal2vulkan](https://github.com/aquarat/metal2vulkan) (LGPL-3.0).
This project does not include or redistribute macOS, Apple firmware or Xcode.

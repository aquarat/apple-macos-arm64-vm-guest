# macOS CI runners on Asahi Linux

This project runs macOS virtual machines on Apple Silicon Macs that run
Fedora Asahi Remix, and uses them as headless, ephemeral CI runners for Xcode
and iOS-simulator jobs.

Guests are macOS 13 Ventura and macOS 26 Tahoe, in QEMU's `vmapple` machine
with KVM. Every CI job gets a fresh guest: a reflink clone of a read-only
golden image, booted for that job and discarded afterwards. An optional memory
balloon gives an idle guest's spare memory back to the host. A runner slot can
have a paravirtual GPU, so its guests get Metal: Reims translates the guest's
Metal commands to Vulkan and runs them on the host GPU through Mesa's
Honeykrisp driver.

It is for people who want macOS CI capacity on Apple Silicon machines that run
Linux, with Forgejo Actions or GitHub Actions.

It runs production CI every day. An M1 Ultra host runs two runner slots, one
of them with the GPU, for an iOS app's Forgejo Actions jobs, including its
XCUITest suite.

What it provides:

- KVM patches for the host kernel, and a script that builds them into a
  Fedora kernel RPM;
- build scripts for the QEMU and Reims forks and for a patched Mesa Vulkan
  driver;
- a recipe and one script per layer to build golden images from an Apple
  restore image: account, Command Line Tools, Xcode, the iOS simulator
  runtime, runner binaries and common CI tools;
- `vm-job.sh`, which runs one command in a throwaway guest;
- ephemeral runner orchestrators for Forgejo Actions and GitHub Actions, with
  systemd units, a persistent Actions cache and optional bridged networking
  per slot;
- a balloon governor that sizes each guest's memory to what it uses.

## Results

On the 2026-10-10 GPU build, simulator unit tests in a macOS 26 guest with
the GPU take as long as without one (a median of 156.4 s over four runs,
against 154.4 s and 160.0 s).
The UI tests of an app that cannot run without a GPU run about 1.6x faster
than on the earlier GPU build. Since the QEMU used-ring fix, no macOS 26 boot
in 200 has stalled (17 of 203 before). Charts, method and more results:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

[![iOS simulator unit tests: GPU builds against no GPU](docs/benchmarks/unit-test.svg)](docs/PERFORMANCE.md#simulator-unit-tests)

[![UI tests on a GPU-accelerated macOS 26 guest](docs/benchmarks/ui-tests.svg)](docs/PERFORMANCE.md#ui-tests)

## How it fits together

| Layer | What this project uses |
| --- | --- |
| Host kernel | Fedora Asahi `kernel-16k` 7.1.13 plus two KVM patches (`patches/linux-7.1.13-*`): Apple's pointer-authentication VM-key registers, and in-KVM emulation of a GIC store that XNU makes without an instruction syndrome. `scripts/build-host-kernel.sh` builds them into an RPM from the host's own base SRPM. |
| QEMU | [aquarat/qemu-reims-vgpu](https://github.com/aquarat/qemu-reims-vgpu): upstream QEMU, steelbrain's `vmapple`/Reims branch, KVM support and fixes for macOS guests (list in [NOTES.md](docs/NOTES.md#qemu--reims-build)). `scripts/build-qemu.sh` builds it as Reims' `vendor/qemu`. No patch files. |
| GPU | [aquarat/reims-vgpu](https://github.com/aquarat/reims-vgpu), a fork of [steelbrain-bot/reims-vgpu](https://github.com/steelbrain-bot/reims-vgpu). GPU slots render on Honeykrisp, Mesa's Asahi Vulkan driver, built with `patches/mesa/` by `scripts/build-mesa-honeykrisp.sh`. Other slots run without a GPU (`GFX=none`). |
| Guest images | A chain of read-only golden bundles, one layer per script in `images/` ([docs/IMAGES.md](docs/IMAGES.md)). |
| CI | `scripts/forgejo-ephemeral-runner.sh` and `scripts/gha-ephemeral-runner.sh`: one runner registration and one throwaway guest per job. |

## Requirements

### Hardware

- An Apple Silicon Mac that runs Asahi Linux. The current flow runs on M1 Max
  (t6001) and M1 Ultra (t6002). Other SoCs are untested; the M2 Pro ran only
  the [legacy flow](docs/LEGACY-BRINGUP.md).
- CPUs and memory for the guests plus the host. The examples here give a
  guest 8 vCPUs and 12–24 GiB.
- A btrfs (or XFS) filesystem that holds both the images and this checkout,
  so clones are reflinks. About 25 GB per base bundle, 10 GB more for Xcode,
  9 GB more for the iOS runtime, and room for the running clones.
- Wired Ethernet for baking images (the 8.5 GB simulator runtime crawled over
  Wi-Fi) and for bridged per-slot networking.

### Host software

- Fedora Asahi Remix 44.
- The patched host kernel (above). Fedora makes every newly installed kernel
  the default, so hold kernel updates or rebuild the patches for each new
  kernel. `dmesg` must show `ACTLR virtualization (IMPDEF, Apple)`.
- Build dependencies for QEMU and Reims (listed in
  [NOTES.md](docs/NOTES.md#qemu--reims-build)), plus `socat`, `python3`,
  `zstd`, and `gdb` for one image step.
- For a GPU slot: access to `/dev/dri/renderD*` and Mesa's build
  dependencies (`sudo dnf builddep mesa`).

### Apple software you supply

This project contains no Apple software. You need:

- `AVPBooter.vmapple2.bin`, the VM boot ROM, from a Mac's
  Virtualization.framework;
- a macOS restore image (IPSW). `images/host/macos-restore.sh` downloads the
  pinned one from Apple's CDN and checks its hash;
- a native macOS host, once, to run the restore with Virtualization.framework.
  The Asahi machine's own macOS installation works;
- an Xcode `.xip` from developer.apple.com, which needs an Apple ID.

Never commit or publish these files, or golden images built from them.

## Quick start

The full image recipe, with checks for every step, is
[docs/IMAGES.md](docs/IMAGES.md). In outline:

1. **Host kernel.** Build from the source RPM of the kernel you run, install
   it beside the default kernel, and boot it once before making it the
   default:

   ```sh
   scripts/build-host-kernel.sh <base.src.rpm> vmapple2
   scripts/fedora-test-kernel.sh install <rpm-dir> <version-release.arch>
   scripts/fedora-test-kernel.sh boot-once <kernel-release>
   ```

2. **QEMU.** `scripts/build-qemu.sh` clones and builds the forks into
   `build/qemu-fleet` and writes `build/qemu-fleet/BUILD-MANIFEST` (the Reims
   and QEMU commits and the binary's hash). `scripts/check-host.sh` then checks
   KVM access and the binary.

3. **GPU (optional).** `scripts/host-gpu-setup.sh` sets up huge pages for
   shared guest memory, builds the patched Honeykrisp driver into
   `~/opt/mesa-honeykrisp`, and prints the `VK_DRIVER_FILES` line to use.

4. **Images.** Restore macOS on a Mac, create the guest account from a
   single-user boot, then bake the layers on the Linux host
   ([docs/IMAGES.md](docs/IMAGES.md)). Put AVPBooter in `artifacts/firmware/`
   or point `AVPBOOTER` at it.

5. **Smoke test.** Run one command in a throwaway guest:

   ```sh
   GOLDEN=~/vm-artifacts/tahoe-26.4-25E246-v13 scripts/vm-job.sh 'sw_vers; xcodebuild -version'
   ```

6. **Runner.** Write a host profile and install the runner service
   ([Operating it](#operating-it)).

## Operating it

### Throwaway guests

```sh
scripts/vm-job.sh '<command>'                       # one throwaway guest, stdin passed through
GOLDEN=~/vm-artifacts/<bundle> CPUS=8 RAM=16G scripts/vm-job.sh …
GOLDEN=~/vm-artifacts/<bundle> scripts/vm-run.sh start <name>   # a guest you manage yourself
scripts/vm-run.sh status|qmp|screenshot|quit <name>
```

`vm-job.sh` clones the golden bundle, boots it (retrying from a fresh clone
if it never reaches SSH), runs the command over SSH, shuts the guest down and
deletes the clone. It exits with the command's status, 124 for a job timeout,
123 for an idle timeout (see `JOB_START_PATTERN` in its header) or 125 for a
guest that never booted. The guest's logs (serial console, QEMU
launcher, Reims, balloon governor, `env.txt`) are kept in
`artifacts/job-logs/<job>/`.

Settings are environment variables. The common ones: `GOLDEN`, `CPUS`, `RAM`,
`GFX` (`reims` or `none`), `VK_DRIVER_FILES`, `BALLOON=1`, `AUDIO`
(`virtio`, `usb` or `none`), `TAP_IF` for a second NIC, `JOB_TIMEOUT`,
`BOOT_RETRIES`, `KEEP=1`. Each script's header comment lists the rest.

`vm-run.sh start` waits for a free macOS instance slot before it boots
(Apple's licence allows two macOS VMs per Mac; the QEMU fork also refuses a
third). On a host that runs the runner service, stop the service before
baking or testing there, or the bake waits.

### CI runners

The orchestrators run N slots. Each slot loops: register a one-job runner,
boot a fresh guest with `vm-job.sh`, run the runner in it, discard the guest.
Credentials reach the guest over SSH stdin, never on a command line.

```sh
set -a; . hosts/<host>.env; set +a
FORGEJO_URL=https://forgejo.example FORGEJO_TOKEN=… FORGEJO_SCOPE=repos/<owner>/<repo> \
    scripts/forgejo-ephemeral-runner.sh "$VM_SLOTS"     # runs-on: macos-26-arm64
GH_TOKEN=… GH_SCOPE=repos/<owner>/<repo> scripts/gha-ephemeral-runner.sh "$VM_SLOTS"
```

For production, run them as services:

- **Host profile.** Copy `hosts/example.env.example` to
  `hosts/<short hostname>.env` (git-ignored) and set `VM_SLOTS`, `CPUS`,
  `RAM`, `GOLDEN`, and optionally `GFX=none`, `BALLOON=1`,
  `NET_TAP_PREFIX=vmtap` and the GPU settings below.
- **Service.** `systemd/vmapple-forgejo-runner.service` or
  `systemd/vmapple-gha-runner.service` runs the orchestrator through
  `scripts/runner-service.sh`. The install steps are in each unit's header;
  replace `User=` and the checkout path first. Credentials go in
  `/etc/vmapple-runner/*.env`. Run one of the two units per host, since both
  count against the two-guest limit.
- **Forgejo.** API mode (`FORGEJO_TOKEN` + `FORGEJO_SCOPE`) or
  registration-token mode (`FORGEJO_REGISTRATION_TOKEN`); both need
  Forgejo 15 or later. Default labels are `macos-26-arm64` and `macos`
  (`RUNNER_LABELS`). Before a slot takes a job it waits for the guest's
  CoreSimulatorService, and a guest-side watchdog flushes a stale negative
  DNS answer for the forge.
- **Limits.** A guest that has had no job for `IDLE_TIMEOUT` (15 min) is
  replaced by a fresh one. A job may run for `JOB_TIMEOUT` (30 min), counted
  from when the runner picks it up; a job that sets `timeout-minutes` gets
  that instead, up to `JOB_MAX_TIMEOUT` (3 h). A job over its limit is
  cancelled through the runner, so Forgejo shows it cancelled, with its log.
  In registration-token mode a slot hands an unused registration on to its
  next guest, so idle guests leave no offline runners behind.
- **Actions cache.** `systemd/vmapple-runner-cache.service` runs a persistent
  `forgejo-runner cache-server` on the host, so `actions/cache` survives the
  throwaway guests ([IMAGES.md](docs/IMAGES.md#runner-cache)).
- **Linux jobs** need no VM: `systemd/forgejo-runner-docker.service` runs
  them in Docker containers on the same host, with the same cache.
- **Bridged NICs.** `sudo scripts/host-net-setup.sh taps br0 <slots>` plus
  `NET_TAP_PREFIX=vmtap` gives each slot a second NIC on the LAN with a
  stable MAC. The user-mode NIC stays the management path.

Stopping the service shuts every guest down and deletes its clone. A job
that is running at that moment fails, so restart when the slots are idle.
More detail: [NOTES.md](docs/NOTES.md#ephemeral-ci-runners).

### GPU slot

Jobs that need Metal, such as UI tests of apps that draw with Metal, run on a
GPU slot. Setup, on top of the above:

1. `scripts/host-gpu-setup.sh` (once, and again after Fedora updates Mesa).
2. A golden image with layer 65 (`images/65-gpu-headless.sh`), baked with the
   GPU on.
3. In the host profile (Forgejo orchestrator only):

   ```sh
   GFX=none                          # slots without the GPU
   GPU_SLOTS=2                       # slot numbers that boot with the GPU
   GPU_GOLDEN=$HOME/vm-artifacts/tahoe-26.4-25E246-v14
   GPU_VK_DRIVER_FILES=<the path host-gpu-setup.sh printed>
   ```

A GPU slot also offers the label `macos-26-arm64-gpu` (`GPU_LABELS`) and
takes ordinary jobs too. With the GPU on, guest RAM is a shared memfd. Reims'
failure log is kept with the job's logs, capped at 64 MiB.

Mesa's llvmpipe (the default `VK_DRIVER_FILES`) is a software fallback. It
renders the desktop, but booting an iOS simulator with it aborts QEMU on an
FP16 shader. For simulator jobs, use Honeykrisp or `GFX=none`.

### Memory balloon

`BALLOON=1` adds a virtio balloon, and `vm-job.sh` runs
`scripts/balloon-governor.py` next to each job. An idle 10 GiB guest then
holds 4.84 GB of host memory on average instead of 8.78 GB. When a job
needs the memory, the governor deflates the balloon on the first sign of
memory pressure. Tunables and measurements:
[NOTES.md](docs/NOTES.md#memory-balloon-macos-guests).

### Golden images

Bundles are named `<os>-<version>-<build>-vN`, and N only grows. The
reference Tahoe chain ends at `-v13` (Xcode 26.4.1, iOS 26.4.1 simulator,
CI tools, simulator warm-up, `audiomxd` off) and `-v14` (layer 65, for GPU
slots). Images contain macOS, the VM identity, your SSH keys and the guest
account's password: keep them private. Recipe, conventions, verifying and
moving bundles between hosts: [docs/IMAGES.md](docs/IMAGES.md).

### Updates

- **Host kernel.** A stock kernel update does not carry the patches. Build
  the new kernel with `scripts/build-host-kernel.sh` from its SRPM, test it
  with `fedora-test-kernel.sh boot-once`, then make it the default.
- **Mesa.** After Fedora updates Mesa, rerun `scripts/host-gpu-setup.sh`. It
  builds the matching Mesa release with the patches.
- **QEMU and Reims.** `scripts/build-qemu.sh [OUTDIR]` updates and rebuilds a
  checkout in place (`REIMS_REF` picks a branch). To test a build before
  using it, build into a new OUTDIR and run `vm-job.sh` with `QEMU_BIN` (or
  `GPU_QEMU_BIN`) pointing at it. `scripts/sync-upstream.sh merge|build|push`
  merges upstream QEMU and Reims into the forks.
- **Images.** Bake a new layer into a new `vN`, check it with `vm-job.sh`,
  then point `GOLDEN` or `GPU_GOLDEN` in the host profile at it and restart
  the service when idle.

## Known limitations

- **Two macOS guests per Mac.** Apple's macOS licence allows at most two
  virtualised macOS instances per Mac. The QEMU fork and `vm-run.sh` enforce
  this, so a host runs at most two CI slots, and a bake on a runner host
  waits for a free slot.
- **Patched host kernel.** KVM needs two patches that are not in the Asahi
  kernel. Kernel and hypervisor changes can crash or reboot the host: keep a
  stock kernel boot entry.
- **Apple software is not included.** You supply AVPBooter, the restore
  image and Xcode, and the restore needs macOS once. The Linux-only restore
  path is unfinished.
- **Tested configurations.** Hosts: M1 Max and M1 Ultra on Fedora Asahi
  Remix 44, kernel 7.1.13. Guests: macOS 13.6 (22G120) and 26.4 (25E246),
  Xcode 26.4.1. Other combinations are untested.
- **GPU rendering gaps.** Compose/Skia apps now render their real UI, but
  a cold app launch takes 20–40 s before the UI settles: the drain is
  bounded by one queue submission per draw. XCTest screenshots taken early
  in a launch can still show a splash or flat colour.
- **GPU slot open issues** ([PERFORMANCE.md](docs/PERFORMANCE.md)):
  `memcpy` is still about two thirds of the drain's CPU time: Honeykrisp
  cannot import guest RAM, so guest data is copied into and out of Vulkan
  memory once each way. GPU slots need Honeykrisp Mesa built with this
  project's patches (`patches/mesa/`, `scripts/build-mesa-honeykrisp.sh`),
  not the distribution's Mesa. llvmpipe
  cannot run the iOS simulator. Only the Forgejo orchestrator has per-slot
  GPU settings.
- **Guests without a GPU** have no Metal. Apps that need Metal cannot run
  their UI tests there, and in a macOS 26 guest WindowServer aborts about
  once a minute. Non-GPU slots accept this because each guest lives for one
  job; do not keep such guests running for hours.
- **Boot retries.** With the used-ring fix no boot stalled in 200, but
  `vm-job.sh` and `bake-golden.sh` keep their retry from a fresh clone as a
  safety net. `bake-xcode.sh` and `create-account.sh` do not retry.
- **Guest settings that cannot be changed** from inside a 26.4 image:
  automatic software-update checks (needs a configuration profile) and
  XProtect (needs SIP off). Both cost a little CPU in every guest.
- **Slow image steps.** Installing Xcode from a `.xip` takes about 1.5 hours
  in a guest.
- **Runner registrations.** In registration-token mode, a slot that is
  stopped before it gets a job leaves an offline runner in Forgejo until an
  admin removes it. API mode deletes it.
- **Fixed guest user.** `bake-golden.sh`, `bake-xcode.sh` and `vm-job.sh` log
  in with a fixed account name; create that account at step 05 or change the
  scripts ([IMAGES.md](docs/IMAGES.md#conventions)).
- **Audio** output is discarded (QEMU's `none` backend), and guests have no
  audio input.

## Licence and legal

- This project does not include or redistribute macOS, Apple firmware or
  Xcode, and does not bypass Apple's restore signing. Restores go through
  Apple's personalisation server.
- Follow Apple's licence terms for macOS and Xcode, including the limit of
  two macOS VMs per Mac.
- Never commit firmware, IPSWs, restore images, VM disks, VM identities or
  logs. `.gitignore` covers the expected locations and formats.
- This project is licensed under GPL-2.0-or-later ([LICENSE](LICENSE)).
  Exceptions are listed in [LICENSING.md](LICENSING.md): files by the
  original upstream author, Anees Iqbal (steelbrain), which remain his and
  are not licensed, and the patches in `patches/`, which follow the licence
  of the project they patch.
- The QEMU and Reims changes live in the forks, which keep their upstream
  licences.

Support: this is maintained for its own production use, with no support
promise. Reports with exact host, kernel, QEMU, firmware and guest versions
are welcome.

## Further reading

- [docs/IMAGES.md](docs/IMAGES.md): building the golden image chain, layer by
  layer, and the runner cache.
- [docs/NOTES.md](docs/NOTES.md): technical notes: kernel patches, QEMU fork
  changes, macOS 26 bring-up, the `avp,rtc` clock, the virtio ring bug, the
  balloon, audio, runner design.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): benchmarks, reliability data,
  how the GPU bugs were found, and how to update the charts.
- [docs/LEGACY-BRINGUP.md](docs/LEGACY-BRINGUP.md): the first bring-up on an
  M2 Pro with a GUI window, and the unfinished Linux restore experiment.

## Credits

- [Reims](https://github.com/steelbrain-bot/reims-vgpu), the QEMU
  `vmapple`/Reims branch and [metal2vulkan](https://github.com/steelbrain/metal2vulkan)
  by steelbrain. This project's GPU support is built on them.
- QEMU and its `vmapple` machine, the [Asahi Linux](https://asahilinux.org/)
  project, and Mesa's Honeykrisp driver.
- [macosvm](https://github.com/s-u/macosvm) for restores on macOS.

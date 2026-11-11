# Provenance of the launcher and provisioning scripts

On 2026-11-11 this project replaced the remaining code by the repository's
original author, Anees Iqbal (steelbrain), in its current flow. That code
has no licence (see [LICENSING.md](../LICENSING.md)). The replacement is an
independent implementation under `GPL-2.0-or-later`. This page records how
it was written and how it was checked.

## What was replaced

| Before | After |
| --- | --- |
| `scripts/launch-kvm.sh` (his lines plus this project's) | `scripts/launch-kvm.sh`, `scripts/lib/qemu-select.sh` |
| `scripts/launch-gui-kvm.sh` | `scripts/launch-gui-kvm.sh` |
| `scripts/check-host.sh` | `scripts/check-host.sh` |
| `scripts/extract-ecid.py` | `scripts/extract-ecid.py` |
| `scripts/provision-on-macos.sh` | `scripts/provision-on-macos.sh` |
| `scripts/inject-xnu-kvm.sh`, `scripts/inject-xnu-kvm.gdb`, `scripts/apple_device_tree.py` | `scripts/inject-xnu-kvm.sh`, `scripts/lib/xnu_handoff.py` |
| His passages in `AGENTS.md` and `README.md` | Reworded |

The legacy-only scripts listed in LICENSING.md are still his and were not
rewritten.

## Method

The work was done by AI agents (Claude), in two separated roles.

1. **Specification.** One agent read the existing scripts and wrote a
   functional specification: environment variables, defaults, checks and
   their order, the QEMU command line and environment for each setting, log
   formats that other scripts parse, exit statuses, and the data formats the
   XNU injector reads and changes (XNU's `boot_args` layout, Apple's device
   tree format, and the instruction sequence of the GIC store). It described
   behaviour, not code. Error messages were left to the implementer.
2. **Implementation.** A second agent, which never saw the original files,
   wrote the scripts. It was given:
   - the specification;
   - an export of the repository with his files removed, and with his lines
     in `launch-kvm.sh` and `AGENTS.md` replaced by a marker;
   - a black-box test harness.
   
   It was forbidden to open the repository's checkouts, its history, the
   upstream repository or its forks. Its report lists every source it used.
3. **Black-box harness.** The harness runs the scripts against stand-ins for
   QEMU and the GPU backend and records exit status, the QEMU command line
   and environment, and the supervisor logs that `scripts/vm-job.sh` parses.
   It has 60 cases. The expected results were recorded from the old scripts.
   The only exception is the two GPU-backend failure cases, which encode the
   intended behaviour (see below).

During implementation, the second agent opened the device-tree headers of
[m1n1](https://github.com/AsahiLinux/m1n1) as a format reference. It then
found that m1n1's maintainers do not accept use of their project by AI
tools. It stopped and wrote the device-tree parser from the specification
alone.

## Checks

- **Harness:** all 60 cases match. The command line and environment QEMU
  receives are identical to those from the old scripts for every setting
  tested.
- **Guests on an M1 Max host** (Fedora Asahi Remix, kernel 7.1.13 with this
  project's patches):
  - macOS 26.4 and 13.6 boot and run a workload with `INJECT=0`.
  - With the out-of-process GPU backend on Honeykrisp, the guest boots and
    the backend's exit is logged.
  - With `INJECT=1` on both versions, the guest sees the injected boot
    arguments and `/chosen/asmb` `lp-sip0` = 0x2, and the GIC store is found
    exactly once and patched. `KVM_MMIO_PATCH=0` skips the patch.
  - `images/host/create-account.sh` creates a working account from a
    pristine 26.4 restore through the new injector.
- **Old against new**, same host and images, `INJECT=1`: `kern.bootargs`,
  `lp-sip0` and `csrutil status` are identical. Both report SIP as enabled,
  even with `lp-sip0` = 0x2.
- **Other tests:**
  - `provision-on-macos.sh` with stand-ins for `macosvm` and `shasum`;
  - the injector against simulated memory and against real GDB and QEMU
    with a small bare-metal program;
  - shellcheck.

Not tested: `provision-on-macos.sh` on real macOS, the injector without a
QMP socket against a real guest, `GPU_BACKEND_LOSS=reset` with a real
backend, and `CONSOLE=gtk` on a real display.

## Differences from the old scripts

- **GPU backend supervisor.** In the old `launch-kvm.sh` the supervisor
  subshell inherited `set -e`, so a failing backend ended it silently: no
  `gpu backend: ...` log line, and `GPU_BACKEND_LOSS=reset` never restarted
  the backend. The new supervisor logs every exit and restarts as
  configured.
- **QEMU choice.** `scripts/lib/qemu-select.sh` holds the choice of QEMU.
  `launch-kvm.sh` and `check-host.sh` both use it, and `launch-kvm.sh`
  passes its choice to `check-host.sh`.
- **Stale sockets.** Only actual sockets are removed. Anything else at a
  socket path is an error.
- **Settings.**
  - `XNU_BOOT_ARGS` and `CSR_CONFIG`, set but empty, now mean empty: no
    boot arguments and no SIP change, rather than the defaults.
  - `INJECT` and `KVM_MMIO_PATCH` accept only `0` or `1`.
- **`launch-gui-kvm.sh`** stops QEMU with SIGINT, then SIGKILL after 30 s.
- **The injector**
  - plans all its writes before making any, so a refusal leaves guest
    memory untouched;
  - checks the gdbstub's view of memory against physical memory;
  - reads back every write;
  - reads guest memory through QMP `pmemsave` when a QMP socket is given.

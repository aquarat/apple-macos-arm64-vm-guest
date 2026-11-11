<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Working agreement for this repository

## Objective

Run macOS arm64 guests on Apple Silicon hosts running Asahi Linux (KVM,
QEMU's `vmapple` machine, an Apple-provided `AVPBooter.vmapple2.bin`) as
headless, ephemeral CI runners, and keep that tooling reliable. It runs
production CI: changes must not break a working runner host.

## Working rules

- Prefer small, inspectable scripts and reproducible commands over
  undocumented manual steps.
- Keep the documentation current: `README.md` (what it is, requirements,
  quick start, operating, limitations), `docs/IMAGES.md` (image recipe),
  `docs/NOTES.md` (reusable technical findings: exact commands, versions,
  checksums, relevant error output) and `docs/PERFORMANCE.md` (benchmarks;
  edit the CSVs in `docs/benchmarks/data/` and rerun
  `scripts/plot-benchmarks.py`, never the SVGs by hand). This repository is
  public: keep machine names, addresses, domains, private project names and
  other host-specific details out of it (`hosts/*.env` is ignored for that
  reason).
- Apple's licence allows two macOS guests per Mac. A runner service's
  guests count; stop the service before baking or testing on a runner host
  (`vm-run.sh` otherwise waits for a free slot). Stopping it discards the
  jobs in flight.
- Nothing large or proprietary goes into git: no Apple firmware, IPSWs or
  other restore images, VM disks, machine identifiers (`vm.json`) or similar
  artefacts. They belong under the ignored `artifacts/` directory or outside
  the repository, and `.gitignore` must keep covering them.
- Anything reasonably needed for the objective is authorised in advance:
  downloads, sparse disk allocation, package installs and removals,
  kernel-module operations, permission changes scoped to the task, and
  restarting experiment processes. Say what you are doing as you go: sizes,
  purposes and every change to the host.
- Keep host changes narrow. Nothing irreversible, and nothing unrelated to
  the task at hand.
- Scripts use `set -euo pipefail`, quote paths, check their prerequisites
  before doing any work and
  default to non-destructive behavior. Exception: `vm-job.sh`,
  `balloon-squeeze.sh`, `debug/boot-reliability.sh` and the runner
  orchestrators use `set -uo pipefail` on purpose, so they can capture a
  failing job's status and still shut the guest down and clean up.
- For QEMU and provisioning code, record the upstream URL and commit ID, and
  pin a known-good revision rather than following a moving branch.
- Preserve failed approaches in the notes; they are useful evidence.

## Definition of done

The repository keeps a reproducible, documented flow that:

1. verifies the Asahi/KVM host and builds the patched kernel, QEMU and
   (for GPU slots) Mesa,
2. builds golden images from user-supplied Apple restore material,
3. runs one CI job per throwaway guest with KVM and persistent logs, and
4. documents its known limitations honestly.

A change is done when it has been exercised on a host (a `vm-job.sh` run,
or boot loops with `scripts/debug/boot-reliability.sh` for boot-path
changes) and the documentation above matches the scripts.

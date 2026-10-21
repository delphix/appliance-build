# upgrade-scripts tests

Run commands in this document from `upgrade/upgrade-scripts/tests`.

## Test flow for recent `upgrade-container` changes

This validates the new commands/features:

- `list-started`
- `list-all`
- `cleanup <container>`

### Prerequisites

- Run on a target appliance/test box as `root`
- `machinectl` is available
- `upgrade-container` script is present and executable

### Test script

Use:

- `./test-upgrade-container-changes.sh`

Optional flags:

- `--type <in-place|not-in-place|rollback>` (default: `in-place`)

Examples:

- `./test-upgrade-container-changes.sh`
- `./test-upgrade-container-changes.sh --type not-in-place`

### What the harness verifies

- Created container appears in `list-all`
- Stopped container does not appear in `list-started`
- Running container appears in `list-started`
- `cleanup <container>` stops (if needed) and destroys the container

### Expected output

The script prints status lines like:

- `[INFO] ...`
- `[PASS] ...`
- `[FAIL] ...` (and exits non-zero)

A successful run ends with:

- `[PASS] All requested tests completed`

### Quick smoke test (manual)

Use this when you want a minimal, fast validation without running the full harness.

1. Create and start one test container:

	- `c=$(../upgrade-container create in-place)`
	- `../upgrade-container start "$c"`

2. Verify listing commands:

	- `../upgrade-container list-all | grep -Fx "$c"`
	- `../upgrade-container list-started | grep -Fx "$c"`

3. Preview and clean up:

	- `../upgrade-container cleanup "$c"`
	- `../upgrade-container list-all | grep -Fx "$c" && echo "unexpected" || echo "clean"`

Expected result:

- The container appears in both list commands while running.
- After `cleanup`, the container is no longer returned by `list-all`.

Automated equivalent:

- `./smoke-upgrade-container.sh`
- Optional type: `./smoke-upgrade-container.sh --type not-in-place`

### Safety notes

- The harness always performs real create/start/destroy operations for its test containers.
- The script includes best-effort exit cleanup for containers it creates.

## `rootfs-cleanup`'s snapshot filter

Use:

- `./test-rootfs-cleanup.py`

### Prerequisites

`python3`, and `dpkg`, which `rootfs-cleanup` uses to compare versions. The
test runs `rootfs-cleanup` itself with stand-ins for `zfs`,
`get-appliance-version` and `rootfs-container` on `PATH`
(`rootfs-cleanup-stubs/`), over an inventory it supplies, so it needs no
appliance, no pool and no `root`.

### What the harness verifies

- No `container-delphix` snapshot reaches the deletion-candidate list, on a
  boot environment carrying eleven of them.
- An unrecognised snapshot name aborts the script, wherever it sits in the
  list relative to a `container-delphix` snapshot.

### Expected output

Standard `unittest` output, ending in `OK`.

## The `/tmp` and `/var/tmp` datasets an upgrade container is built with

Use:

- `./test-upgrade-container-tmp-datasets.py`

### Prerequisites

`python3`, and `dpkg`, which `common.sh` uses to compare versions. The test runs the real
`upgrade-container` with stand-ins for the commands it shells out to
(`upgrade-container-stubs/`) over an inventory it supplies, so it needs no appliance and no
pool. `upgrade-container` does need root, and writes to `/var/lib/machines` and
`/etc/systemd`, so the test re-runs itself in a user and mount namespace with a scratch
directory bound over each of those, and over `/var/tmp`. Nothing it writes reaches the host.
On hosts that restrict unprivileged user namespaces, run it as `root` instead.

### What the harness verifies

- A container created from a boot environment that has `tmp` and `vartmp` datasets gets a
  clone of each, and an fstab that mounts them at `/tmp` and `/var/tmp` with `nosuid,nodev`.
- Those datasets are looked for on the snapshot the clones come from, under a name `zfs`
  accepts.
- A container created from a boot environment without them gets neither the datasets nor the
  fstab entries.
- A `rollback` container, which is cloned from the snapshot `execute` took before the
  upgrade, gets whichever of the two that snapshot holds, and is created without them
  rather than failing when it holds neither.
- `destroy` unmounts the container's `tmp` and `vartmp` datasets before destroying it.

### Expected output

Standard `unittest` output, ending in `OK`.

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

## `upgrade-container`'s teardown

Use:

- `./test-upgrade-container-teardown.py`

### Prerequisites

`python3` and `unshare(1)`. The test runs `upgrade-container` itself inside a
user and mount namespace, with stand-ins for the commands it shells out to on
`PATH` (`upgrade-container-stubs/`) and tmpfs over `/etc/systemd/nspawn`,
`/etc/systemd/system` and `/var/lib/machines`, so it needs no appliance, no
pool and no `root`.

### What the harness verifies

- A `destroy` that fails because the container is still running leaves the
  container's markers in place, so `list-all` still reports it.
- `cleanup <container>` reclaims a container left behind by such a `destroy`,
  once the container can be terminated.
- An ordinary `destroy` of a stopped container still removes every marker,
  dataset and snapshot it owns.
- `cleanup <container>` destroys nothing while the container will not stop.

### Expected output

Standard `unittest` output, ending in `OK`.

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

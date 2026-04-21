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

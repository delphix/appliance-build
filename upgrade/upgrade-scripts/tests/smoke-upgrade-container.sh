#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UC_SCRIPT="$SCRIPT_DIR/../upgrade-container"

TYPE="in-place"
SMOKE_CONTAINER=""

usage() {
	cat <<-EOF
	Usage: $(basename "$0") [--type <in-place|not-in-place|rollback>]

	Runs a quick smoke validation for recent upgrade-container changes:
	  1) create + start one container
	  2) verify list-all and list-started include it
	  3) cleanup and verify removal
	EOF
}

log() {
	echo "[INFO] $*"
}

pass() {
	echo "[PASS] $*"
}

fail() {
	echo "[FAIL] $*" >&2
	exit 1
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			[[ $# -ge 2 ]] || fail "missing value for --type"
			TYPE="$2"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			fail "unknown argument: '$1'"
			;;
		esac
		shift
	done

	case "$TYPE" in
	in-place | not-in-place | rollback) ;;
	*) fail "invalid type '$TYPE'" ;;
	esac
}

require_prereqs() {
	[[ "$EUID" -eq 0 ]] || fail "must run as root"
	[[ -x "$UC_SCRIPT" ]] || fail "missing executable script: $UC_SCRIPT"
	command -v grep >/dev/null || fail "grep not found"
	command -v machinectl >/dev/null || fail "machinectl not found"
}

contains_line() {
	local output="$1"
	local needle="$2"
	printf '%s\n' "$output" | grep -Fxq "$needle"
}

main() {
	parse_args "$@"
	require_prereqs

	cleanup_on_exit() {
		set +e
		if [[ -n "$SMOKE_CONTAINER" ]]; then
			"$UC_SCRIPT" cleanup "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
		fi
	}
	trap cleanup_on_exit EXIT

	log "Creating container (type=$TYPE)"
	SMOKE_CONTAINER=$("$UC_SCRIPT" create "$TYPE")
	[[ -n "$SMOKE_CONTAINER" ]] || fail "create returned empty container name"
	pass "Created '$SMOKE_CONTAINER'"

	log "Starting '$SMOKE_CONTAINER'"
	"$UC_SCRIPT" start "$SMOKE_CONTAINER"
	pass "Started '$SMOKE_CONTAINER'"

	all_out=$("$UC_SCRIPT" list-all)
	contains_line "$all_out" "$SMOKE_CONTAINER" || fail "list-all did not include '$SMOKE_CONTAINER'"
	pass "list-all includes '$SMOKE_CONTAINER'"

	started_out=$("$UC_SCRIPT" list-started)
	contains_line "$started_out" "$SMOKE_CONTAINER" || fail "list-started did not include '$SMOKE_CONTAINER'"
	pass "list-started includes '$SMOKE_CONTAINER'"

	log "Running cleanup"
	"$UC_SCRIPT" cleanup "$SMOKE_CONTAINER"

	all_after=$("$UC_SCRIPT" list-all)
	if contains_line "$all_after" "$SMOKE_CONTAINER"; then
		fail "container '$SMOKE_CONTAINER' still present after cleanup"
	fi
	pass "cleanup removed '$SMOKE_CONTAINER'"

	SMOKE_CONTAINER=""
	pass "Smoke test completed successfully"
}

main "$@"

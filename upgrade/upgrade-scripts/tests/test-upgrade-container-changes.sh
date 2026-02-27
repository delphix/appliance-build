#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UPGRADE_CONTAINER_SCRIPT="$SCRIPT_DIR/../upgrade-container"

TEST_TYPE="in-place"
RUN_DESTRUCTIVE_ALL=false
TEST_CONTAINER1=""
TEST_CONTAINER2=""

usage() {
	cat <<-EOF
	Usage: $(basename "$0") [--type <in-place|not-in-place|rollback>] [--run-destructive-all]

	Tests recent changes in 'upgrade-container':
	  - list-started
	  - list-all
	  - cleanup (single container)
	  - cleanup --preview
	  - cleanup --all (preview always, destructive optional)

	By default, destructive cleanup of --all is NOT executed.
	Use --run-destructive-all only on a dedicated test box.
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

run_uc() {
	"$UPGRADE_CONTAINER_SCRIPT" "$@"
}

assert_contains_line() {
	local haystack="$1"
	local needle="$2"
	if ! printf '%s\n' "$haystack" | grep -Fxq "$needle"; then
		echo "----- output -----"
		printf '%s\n' "$haystack"
		echo "------------------"
		fail "expected line '$needle'"
	fi
}

assert_not_contains_line() {
	local haystack="$1"
	local needle="$2"
	if printf '%s\n' "$haystack" | grep -Fxq "$needle"; then
		echo "----- output -----"
		printf '%s\n' "$haystack"
		echo "------------------"
		fail "unexpected line '$needle'"
	fi
}

container_running() {
	machinectl status "$1" &>/dev/null
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			[[ $# -ge 2 ]] || fail "missing value for --type"
			TEST_TYPE="$2"
			shift
			;;
		--run-destructive-all)
			RUN_DESTRUCTIVE_ALL=true
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

	case "$TEST_TYPE" in
	in-place | not-in-place | rollback) ;;
	*) fail "invalid type '$TEST_TYPE'" ;;
	esac
}

require_prereqs() {
	[[ "$EUID" -eq 0 ]] || fail "must run as root"
	[[ -x "$UPGRADE_CONTAINER_SCRIPT" ]] || fail "missing executable: $UPGRADE_CONTAINER_SCRIPT"
	command -v machinectl >/dev/null || fail "machinectl not found"
	command -v awk >/dev/null || fail "awk not found"
}

main() {
	parse_args "$@"
	require_prereqs

	local before_all before_started after_all after_started
	TEST_CONTAINER1="uc-test-$(date +%s)-a"
	TEST_CONTAINER2="uc-test-$(date +%s)-b"

	# create uses internally generated names; capture them for test flow
	log "Creating first test container (type=$TEST_TYPE)"
	TEST_CONTAINER1=$(run_uc create "$TEST_TYPE")
	[[ -n "$TEST_CONTAINER1" ]] || fail "create returned empty container name"
	pass "Created '$TEST_CONTAINER1'"

	# Best-effort cleanup on script exit for containers created here.
	cleanup_on_exit() {
		set +e
		for c in "$TEST_CONTAINER1" "$TEST_CONTAINER2"; do
			[[ -n "$c" ]] || continue
			if run_uc list-all | grep -Fxq "$c"; then
				run_uc cleanup "$c" >/dev/null 2>&1 || true
			fi
		done
	}
	trap cleanup_on_exit EXIT

	before_all=$(run_uc list-all)
	assert_contains_line "$before_all" "$TEST_CONTAINER1"
	pass "list-all includes newly created container"

	before_started=$(run_uc list-started)
	assert_not_contains_line "$before_started" "$TEST_CONTAINER1"
	pass "list-started excludes non-running container"

	log "Validating cleanup --preview for stopped container"
	preview_out=$(run_uc cleanup --preview "$TEST_CONTAINER1")
	assert_contains_line "$preview_out" "would destroy container '$TEST_CONTAINER1'"
	assert_not_contains_line "$preview_out" "would stop container '$TEST_CONTAINER1'"
	pass "cleanup --preview on stopped container is correct"

	log "Starting container and validating list-started"
	run_uc start "$TEST_CONTAINER1"
	after_started=$(run_uc list-started)
	assert_contains_line "$after_started" "$TEST_CONTAINER1"
	pass "list-started includes running container"

	log "Validating cleanup --preview for running container"
	preview_running_out=$(run_uc cleanup --preview "$TEST_CONTAINER1")
	assert_contains_line "$preview_running_out" "would stop container '$TEST_CONTAINER1'"
	assert_contains_line "$preview_running_out" "would destroy container '$TEST_CONTAINER1'"
	if ! container_running "$TEST_CONTAINER1"; then
		fail "container should still be running after preview"
	fi
	pass "cleanup --preview does not mutate running container"

	log "Validating cleanup (destructive) for single container"
	run_uc cleanup "$TEST_CONTAINER1"
	after_all=$(run_uc list-all)
	assert_not_contains_line "$after_all" "$TEST_CONTAINER1"
	if container_running "$TEST_CONTAINER1"; then
		fail "container '$TEST_CONTAINER1' still running after cleanup"
	fi
	pass "cleanup destroyed the container"

	log "Creating second test container for --all checks"
	TEST_CONTAINER2=$(run_uc create "$TEST_TYPE")
	[[ -n "$TEST_CONTAINER2" ]] || fail "second create returned empty container name"
	pass "Created '$TEST_CONTAINER2'"

	log "Validating cleanup --preview --all"
	preview_all_out=$(run_uc cleanup --preview --all)
	assert_contains_line "$preview_all_out" "would destroy container '$TEST_CONTAINER2'"
	pass "cleanup --preview --all reports expected action"

	if $RUN_DESTRUCTIVE_ALL; then
		log "Running destructive cleanup --all"
		run_uc cleanup --all
		final_all=$(run_uc list-all)
		assert_not_contains_line "$final_all" "$TEST_CONTAINER2"
		pass "cleanup --all removed all upgrade containers"
	else
		log "Skipping destructive cleanup --all (use --run-destructive-all to enable)"
	fi

	pass "All requested tests completed"
}

main "$@"

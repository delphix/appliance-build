#!/bin/bash
#
# Copyright 2026 Delphix
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# Tests "prepare" against the unpack directories it has to handle: one it
# is seeing for the first time, one an earlier run of itself left behind
# part way through, one that holds an image it has already installed, and
# one that holds no image at all. These cover the user workflow where an
# upgrade image is uploaded and unpacked, the appliance restarts before
# the unpack finishes, and the unpack is run again by hand.
#
# "prepare" requires root and writes only under $UPDATE_DIR, so this runs
# itself in a user namespace when it is not already root. On hosts that
# restrict unprivileged user namespaces, run it as root instead.
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREPARE="$SCRIPT_DIR/../prepare"

IMAGE_VERSION=2026.5.0.2
TEST_ROOT=""

function log() {
	echo "[INFO] $*"
}

function pass() {
	echo "[PASS] $*"
}

function fail() {
	echo "[FAIL] $*" >&2
	exit 1
}

#
# Builds the unpack directory that unpack-image hands to prepare: the
# image's compressed payload and its version.info, and nothing else.
#
function make_unpack_dir() {
	local update_dir=$1
	local unpack_dir

	unpack_dir=$(mktemp -d -p "$update_dir" -t unpack.XXXXXXX)

	mkdir -p "$unpack_dir/payload"
	echo "#!/bin/bash" >"$unpack_dir/payload/upgrade"
	chmod +x "$unpack_dir/payload/upgrade"
	tar -czf "$unpack_dir/payload.tar.gz" -C "$unpack_dir/payload" .
	rm -rf "$unpack_dir/payload"

	{
		echo "VERSION=$IMAGE_VERSION"
		echo "MINIMUM_VERSION=2026.1.0.0"
		echo "MINIMUM_REBOOT_OPTIONAL_VERSION=2026.1.0.0"
	} >"$unpack_dir/version.info"

	echo "$unpack_dir"
}

function make_update_dir() {
	local update_dir="$TEST_ROOT/$1"

	mkdir -p "$update_dir"
	echo "$update_dir"
}

#
# Stops prepare with $signal between its extraction of the payload and its
# move of the image into $UPDATE_DIR, which is the window an appliance
# restart lands in. prepare sources the image's version.info in that
# window, so a read of an empty fifo appended to version.info parks
# prepare there until it is signalled. The appended line is removed
# afterwards, so what is left behind is the state prepare itself leaves.
#
function interrupt_prepare() {
	local update_dir=$1
	local unpack_dir=$2
	local signal=$3
	local fifo="$TEST_ROOT/park.$$"
	local pid waited

	mkfifo "$fifo"
	echo "read -r _ <'$fifo'" >>"$unpack_dir/version.info"

	UPDATE_DIR="$update_dir" "$PREPARE" "$unpack_dir" &
	pid=$!

	waited=0
	while [[ -f "$unpack_dir/payload.tar.gz" ]]; do
		[[ $waited -lt 300 ]] || fail "prepare did not extract the payload"
		sleep 0.1
		waited=$((waited + 1))
	done

	# The shell announces the stopped job on stderr; it is expected here.
	{ kill "-$signal" "$pid" && wait "$pid"; } 2>/dev/null || true
	rm "$fifo"
	#
	# A prepare that deleted the directory leaves nothing to restore; let
	# the caller's assertions report that rather than failing here.
	#
	if [[ -f "$unpack_dir/version.info" ]]; then
		sed -i "/^read -r _ </d" "$unpack_dir/version.info"
	fi
}

function assert_image_is_unpacked() {
	local update_dir=$1

	[[ -d "$update_dir/$IMAGE_VERSION" ]] ||
		fail "'$update_dir/$IMAGE_VERSION' was not created"
	[[ "$(readlink "$update_dir/latest")" == "$IMAGE_VERSION" ]] ||
		fail "'latest' does not point at '$IMAGE_VERSION'"
	[[ -x "$update_dir/$IMAGE_VERSION/upgrade" ]] ||
		fail "the unpacked image is missing its payload"
	[[ -f "$update_dir/$IMAGE_VERSION/version.info" ]] ||
		fail "the unpacked image is missing its version.info"
}

function test_unpacks_a_new_image() {
	local update_dir unpack_dir rc

	update_dir=$(make_update_dir unpacks-a-new-image)
	unpack_dir=$(make_unpack_dir "$update_dir")

	log "Running prepare on a freshly unpacked image"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" "$unpack_dir" || rc=$?

	[[ $rc -eq 0 ]] || fail "prepare exited $rc on a freshly unpacked image"
	assert_image_is_unpacked "$update_dir"
	pass "prepare unpacks a new image into \$UPDATE_DIR"
}

#
# Everything an interrupted prepare leaves behind exists nowhere else:
# unpack-image deletes the uploaded image before it calls prepare. Running
# prepare again over that directory has to finish the unpack.
#
function test_resumes_an_interrupted_unpack() {
	local update_dir unpack_dir rc

	update_dir=$(make_update_dir resumes-an-interrupted-unpack)
	unpack_dir=$(make_unpack_dir "$update_dir")

	log "Killing prepare after it has extracted the payload"
	interrupt_prepare "$update_dir" "$unpack_dir" KILL
	[[ -d "$unpack_dir" ]] ||
		fail "the killed prepare left no unpack directory to resume"
	[[ ! -d "$update_dir/$IMAGE_VERSION" ]] ||
		fail "the killed prepare got as far as unpacking the image"

	log "Running prepare again over the interrupted unpack"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" "$unpack_dir" || rc=$?

	[[ -d "$unpack_dir" || -d "$update_dir/$IMAGE_VERSION" ]] ||
		fail "prepare destroyed the only copy of the image"
	[[ $rc -eq 0 ]] || fail "prepare exited $rc on an interrupted unpack"
	assert_image_is_unpacked "$update_dir"
	pass "prepare finishes an unpack that an earlier run was killed during"
}

#
# A prepare that is terminated rather than killed runs its cleanup on the
# way out, so the window it is stopped in is also a window where it can
# take the image with it.
#
function test_keeps_the_image_when_it_is_terminated() {
	local update_dir unpack_dir

	update_dir=$(make_update_dir keeps-the-image-when-it-is-terminated)
	unpack_dir=$(make_unpack_dir "$update_dir")

	log "Terminating prepare after it has extracted the payload"
	interrupt_prepare "$update_dir" "$unpack_dir" TERM

	[[ -d "$unpack_dir" ]] ||
		fail "prepare deleted the image as it was terminated"
	pass "prepare leaves an extracted image behind when it is terminated"
}

#
# Someone recovering an upgrade by hand cannot tell how far an earlier run
# got, so a run over an image that is already in place has to leave it
# there - including the -f run that "version already exists" invites.
#
function test_keeps_an_image_it_has_already_installed() {
	local update_dir unpack_dir rc

	update_dir=$(make_update_dir keeps-an-image-it-has-already-installed)
	unpack_dir=$(make_unpack_dir "$update_dir")

	UPDATE_DIR="$update_dir" "$PREPARE" "$unpack_dir" >/dev/null ||
		fail "prepare failed to unpack a new image"

	log "Running prepare again over the image it has already installed"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" "$update_dir/$IMAGE_VERSION" 2>/dev/null || rc=$?

	[[ $rc -eq 18 ]] || fail "prepare exited $rc over an installed image, expected 18"
	assert_image_is_unpacked "$update_dir"

	log "Running prepare -f over the image it has already installed"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" -f "$update_dir/$IMAGE_VERSION" 2>/dev/null || rc=$?

	[[ $rc -eq 18 ]] || fail "prepare -f exited $rc over an installed image, expected 18"
	assert_image_is_unpacked "$update_dir"
	pass "prepare leaves an image it has already installed in place, with -f too"
}

#
# A second upload of a version that is already installed is a redundant
# copy rather than the only one, so its space is still reclaimed.
#
function test_reclaims_a_duplicate_of_an_installed_image() {
	local update_dir first second rc

	update_dir=$(make_update_dir reclaims-a-duplicate-of-an-installed-image)
	first=$(make_unpack_dir "$update_dir")
	UPDATE_DIR="$update_dir" "$PREPARE" "$first" >/dev/null ||
		fail "prepare failed to unpack a new image"

	second=$(make_unpack_dir "$update_dir")

	log "Running prepare on a second copy of a version already installed"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" "$second" 2>/dev/null || rc=$?

	[[ $rc -eq 18 ]] || fail "prepare exited $rc on a duplicate version, expected 18"
	[[ ! -d "$second" ]] || fail "prepare left the duplicate behind"
	assert_image_is_unpacked "$update_dir"
	pass "prepare reclaims a duplicate of a version it has already installed"
}

function test_rejects_an_image_with_no_payload() {
	local update_dir unpack_dir rc

	update_dir=$(make_update_dir rejects-an-image-with-no-payload)
	unpack_dir=$(make_unpack_dir "$update_dir")

	rm "$unpack_dir/payload.tar.gz"

	log "Running prepare on an image whose payload is missing"
	rc=0
	UPDATE_DIR="$update_dir" "$PREPARE" "$unpack_dir" 2>/dev/null || rc=$?

	[[ $rc -eq 15 ]] || fail "prepare exited $rc on a corrupt image, expected 15"
	[[ ! -d "$unpack_dir" ]] || fail "prepare left a corrupt image behind"
	pass "prepare rejects an image with no payload and reclaims its space"
}

function main() {
	[[ -x "$PREPARE" ]] || fail "missing executable script: '$PREPARE'"

	TEST_ROOT=$(mktemp -d -t test-prepare.XXXXXXX)
	# shellcheck disable=SC2064
	trap "rm -rf '$TEST_ROOT'" EXIT

	test_unpacks_a_new_image
	test_resumes_an_interrupted_unpack
	test_keeps_the_image_when_it_is_terminated
	test_keeps_an_image_it_has_already_installed
	test_reclaims_a_duplicate_of_an_installed_image
	test_rejects_an_image_with_no_payload

	pass "All prepare tests passed"
}

if [[ "$EUID" -ne 0 ]]; then
	command -v unshare >/dev/null ||
		fail "must be run as root, and 'unshare' is not available"
	exec unshare -r "$0" "$@"
fi

main "$@"

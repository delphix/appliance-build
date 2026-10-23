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
# Tests 96-check-no-baked-credentials.binary. The hook reads only the "binary"
# directory below its working directory and writes nothing, so each case is a
# fixture tree in a temporary directory rather than a build.
#
# Run it from anywhere:
#
#     live-build/config/hooks/tests/test-check-no-baked-credentials.sh
#
# This directory holds tests, not hooks. run-live-build.sh copies only the
# "configuration" directory and the run type's own directory into a build, so
# nothing here is ever run as part of one.
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/../configuration/96-check-no-baked-credentials.binary"

#
# Shaped like a GitHub classic personal access token, so the hook sees what it
# would see in a real image, but spelling out that it is not one so a reader
# who greps a build log for it is not sent looking for a leak.
#
FAKE_TOKEN="ghp_000000000000000000000000TESTONLY"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cases=0
failures=0

pass() {
	echo "[PASS] $*"
}

fail() {
	echo "[FAIL] $*" >&2
	failures=$((failures + 1))
}

#
# Shows what the hook said when an assertion about it fails. The fixtures hold
# only FAKE_TOKEN, so this cannot echo a real credential.
#
dump_output() {
	echo "----- hook output -----" >&2
	echo "$hook_output" >&2
	echo "-----------------------" >&2
}

#
# Starts a case: a fresh fixture root, which the caller fills in and then hands
# to run_hook. Sets $fixture.
#
new_fixture() {
	cases=$((cases + 1))
	fixture="$tmpdir/case-$cases/binary"
	mkdir -p "$fixture"
}

#
# Runs the hook over the fixture. Sets $hook_status and $hook_output; the hook
# is expected to fail in half these cases, so its status is captured rather
# than inherited.
#
run_hook() {
	hook_status=0
	hook_output=$(cd "$(dirname "$fixture")" && "$HOOK" 2>&1) || hook_status=$?
}

#
# Writes a .git/config of the shape git leaves behind after a clone, with the
# given remote URL.
#
make_checkout() {
	local path="$1" url="$2"
	mkdir -p "$fixture/$path/.git"
	cat >"$fixture/$path/.git/config" <<-EOF
		[core]
			repositoryformatversion = 0
			bare = false
		[remote "origin"]
			url = $url
			fetch = +refs/heads/*:refs/remotes/origin/*
		[branch "develop"]
			remote = origin
			merge = refs/heads/develop
	EOF
}

#
# An ansible role that clones over HTTPS with a credential in the URL leaves
# that credential in the checkout's config, which the image then ships. This
# is the case the hook exists to stop, so it asserts the build fails and that
# the message names the file to remove.
#
test_credential_in_git_remote_fails() {
	new_fixture
	make_checkout "home/delphix/dlpx-app-gate" \
		"https://$FAKE_TOKEN@github.com/delphix/dlpx-app-gate.git"

	run_hook
	if ((hook_status == 0)); then
		dump_output
		fail "a credential in a baked .git/config did not fail the build"
		return
	fi
	if ! grep -q "dlpx-app-gate/.git/config" <<<"$hook_output"; then
		dump_output
		fail "the hook failed but did not name the offending .git/config"
		return
	fi
	pass "a credential in a baked .git/config fails the build"
}

#
# The report goes to a build log that far more people can read than can read
# the credential, so it names the file without quoting the secret.
#
test_credential_value_is_not_printed() {
	new_fixture
	make_checkout "opt/devops-gate" \
		"https://$FAKE_TOKEN@github.com/delphix/devops-gate.git"

	run_hook
	if grep -qF "$FAKE_TOKEN" <<<"$hook_output"; then
		fail "the hook printed the credential it found"
		return
	fi
	pass "the hook reports the finding without printing the credential"
}

#
# What the fix leaves behind has to pass: the roles this hook guards reset
# their clones to plain HTTPS, and appliance-build.claude-internal resets its
# own to SSH. Neither carries a credential.
#
test_credential_free_remotes_pass() {
	new_fixture
	make_checkout "home/delphix/dlpx-app-gate" \
		"https://github.com/delphix/dlpx-app-gate.git"
	make_checkout "home/delphix/src/zfs" \
		"git@github.com:delphix/zfs.git"
	make_checkout "opt/dcenter/lib/dcenter-gate" \
		"https://github.com/delphix/dcenter-gate.git"

	run_hook
	if ((hook_status != 0)); then
		dump_output
		fail "credential-free remotes failed the build"
		return
	fi
	pass "credential-free remotes pass"
}

#
# Every customer-facing image is this case: no checkout anywhere.
#
test_image_with_no_checkouts_passes() {
	new_fixture
	mkdir -p "$fixture/etc"

	run_hook
	if ((hook_status != 0)); then
		dump_output
		fail "an image with no checkouts failed the build"
		return
	fi
	pass "an image with no checkouts passes"
}

#
# The hook's other check: pam_env needs /etc/environment world-readable, so a
# credential written there is readable by every user of every VM.
#
test_aws_credential_in_environment_fails() {
	new_fixture
	mkdir -p "$fixture/etc"
	cat >"$fixture/etc/environment" <<-EOF
		AWS_DEFAULT_REGION=us-west-2
		AWS_SECRET_ACCESS_KEY=not-a-real-key
	EOF

	run_hook
	if ((hook_status == 0)); then
		dump_output
		fail "an AWS credential in /etc/environment did not fail the build"
		return
	fi
	if grep -qF "not-a-real-key" <<<"$hook_output"; then
		fail "the hook printed the AWS credential it found"
		return
	fi
	pass "an AWS credential in /etc/environment fails the build"
}

#
# Both checks run on every image, so an image carrying both kinds of
# credential has to report both: a reader who fixes only what the hook named
# would otherwise ship the other one.
#
test_both_kinds_are_reported_together() {
	new_fixture
	mkdir -p "$fixture/etc"
	echo "AWS_SECRET_ACCESS_KEY=not-a-real-key" >"$fixture/etc/environment"
	make_checkout "home/delphix/dlpx-app-gate" \
		"https://$FAKE_TOKEN@github.com/delphix/dlpx-app-gate.git"

	run_hook
	if ((hook_status == 0)); then
		dump_output
		fail "an image with two baked credentials did not fail the build"
		return
	fi
	if ! grep -q "/etc/environment" <<<"$hook_output" ||
		! grep -q "dlpx-app-gate/.git/config" <<<"$hook_output"; then
		dump_output
		fail "the hook reported only one of the two baked credentials"
		return
	fi
	pass "both kinds of baked credential are reported together"
}

#
# The same URL reaches an image by more routes than a clone's remote: a pushurl,
# an insteadOf rewrite in a user's or the system gitconfig, a submodule's or a
# bare repository's config, a worktree's config, or git's credential store.
# Each of these, given its own fixture, has to fail the build, name the file,
# and not print the credential.
#
test_other_credential_forms_fail() {
	local form path content
	while IFS='|' read -r form path content; do
		new_fixture
		mkdir -p "$(dirname "$fixture/$path")"
		printf '%b\n' "$content" >"$fixture/$path"

		run_hook
		if ((hook_status == 0)); then
			dump_output
			fail "a credential in $form did not fail the build"
			continue
		fi
		if ! grep -qF "$path" <<<"$hook_output"; then
			dump_output
			fail "the hook failed on $form but did not name $path"
			continue
		fi
		if grep -qF "$FAKE_TOKEN" <<<"$hook_output"; then
			fail "the hook printed the credential it found in $form"
			continue
		fi
		pass "a credential in $form fails the build"
	done <<-EOF
		a pushurl|home/delphix/zfs/.git/config|[remote "origin"]\n\tpushurl = https://$FAKE_TOKEN@github.com/delphix/zfs.git
		a quoted, upper-case url|home/delphix/zfs/.git/config|[remote "origin"]\n\tURL = "https://$FAKE_TOKEN@github.com/delphix/zfs.git"
		an insteadOf rewrite|home/delphix/.gitconfig|[url "https://$FAKE_TOKEN@github.com/"]\n\tinsteadOf = https://github.com/
		the system gitconfig|etc/gitconfig|[url "https://x-access-token:$FAKE_TOKEN@github.com/"]\n\tinsteadOf = https://github.com/
		an XDG gitconfig|home/delphix/.config/git/config|[url "https://$FAKE_TOKEN@github.com/"]\n\tinsteadOf = https://github.com/
		a submodule's config|home/delphix/zfs/.git/modules/zfs-images/config|[remote "origin"]\n\turl = https://$FAKE_TOKEN@github.com/delphix/zfs-images.git
		a bare repository|srv/git/zfs.git/config|[remote "origin"]\n\turl = https://$FAKE_TOKEN@github.com/delphix/zfs.git
		a worktree's config|home/delphix/zfs/.git/worktrees/wt/config.worktree|[remote "origin"]\n\turl = https://$FAKE_TOKEN@github.com/delphix/zfs.git
		the credential store|root/.git-credentials|https://x-access-token:$FAKE_TOKEN@github.com
		the XDG credential store|root/.config/git/credentials|https://x-access-token:$FAKE_TOKEN@github.com
	EOF
}

#
# git never sends a password from an ssh:// URL, so its userinfo is only a user
# name, as in the "git@" every GitHub SSH remote carries.
#
test_ssh_user_name_passes() {
	new_fixture
	make_checkout "home/delphix/zfs" "ssh://git@github.com/delphix/zfs.git"

	run_hook
	if ((hook_status != 0)); then
		dump_output
		fail "an ssh:// remote with a user name failed the build"
		return
	fi
	pass "an ssh:// remote with a user name passes"
}

#
# The report names the file however the file is named.
#
test_unusual_path_is_named() {
	new_fixture
	make_checkout "home/delphix/a#b&c d" \
		"https://$FAKE_TOKEN@github.com/delphix/zfs.git"

	run_hook
	if ((hook_status == 0)) || ! grep -qF "a#b&c d/.git/config:5:" <<<"$hook_output"; then
		dump_output
		fail "the hook did not name a checkout whose path holds # & and a space"
		return
	fi
	pass "the hook names a checkout whose path holds # & and a space"
}

test_aws_configuration_in_environment_passes() {
	new_fixture
	mkdir -p "$fixture/etc"
	echo "AWS_DEFAULT_REGION=us-west-2" >"$fixture/etc/environment"

	run_hook
	if ((hook_status != 0)); then
		dump_output
		fail "AWS configuration in /etc/environment failed the build"
		return
	fi
	pass "AWS configuration in /etc/environment passes"
}

[[ -x $HOOK ]] || {
	echo "[FAIL] $HOOK is not executable" >&2
	exit 1
}

echo "[INFO] testing $HOOK"

test_credential_in_git_remote_fails
test_credential_value_is_not_printed
test_credential_free_remotes_pass
test_image_with_no_checkouts_passes
test_aws_credential_in_environment_fails
test_both_kinds_are_reported_together
test_aws_configuration_in_environment_passes
test_other_credential_forms_fail
test_ssh_user_name_passes
test_unusual_path_is_named

if ((failures > 0)); then
	echo "[FAIL] $failures of $cases tests failed" >&2
	exit 1
fi

pass "all $cases tests passed"

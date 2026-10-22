#!/bin/bash
#
# The sandbox test-upgrade-container-teardown.py runs "upgrade-container" in.
#
# "upgrade-container" refuses to run as anyone but root, and reads and
# writes /etc/systemd/nspawn, /etc/systemd/system and /var/lib/machines by
# absolute path. A user and mount namespace gives it all three without an
# appliance and without privilege: the caller is root inside it, and the
# three directories are tmpfs holding only what the test put there.
#
# Usage: upgrade-container-sandbox.sh <workdir>
#
# <workdir> holds the fixture to populate the namespace from, the steps to
# run, and everything the run produces. The namespace dies with this
# script, so the final state of the three directories is written back out
# to <workdir>/after.txt before it does.
#
set -euo pipefail

WORKDIR="$1"

[[ "$EUID" -eq 0 ]] || {
	echo "upgrade-container-sandbox.sh: not root; run me under 'unshare --map-root-user --mount'" >&2
	exit 1
}

mount -t tmpfs tmpfs /etc/systemd
mkdir -p /etc/systemd/nspawn /etc/systemd/system
mount -t tmpfs tmpfs /var/lib/machines

cp -a "$WORKDIR/fixture/etc-systemd/." /etc/systemd/
cp -a "$WORKDIR/fixture/var-lib-machines/." /var/lib/machines/

export PATH="$WORKDIR/bin:$PATH"
export STUB_STATE="$WORKDIR/state.json"
export STUB_TRACE="$WORKDIR/trace.txt"

#
# One command per line of steps.txt, run in order in the one namespace.
# A test that has to reach a later state goes through the states before
# it the way an engine would, rather than being handed the end state.
#
step=0
while IFS= read -r command; do
	[[ -n "$command" ]] || continue
	step=$((step + 1))
	rc=0
	eval "$command" >"$WORKDIR/step-$step.out" 2>"$WORKDIR/step-$step.err" </dev/null || rc=$?
	echo "$rc" >"$WORKDIR/step-$step.rc"
done <"$WORKDIR/steps.txt"

{
	echo "## /etc/systemd/nspawn"
	ls -A /etc/systemd/nspawn
	echo "## /etc/systemd/system"
	ls -A /etc/systemd/system
	echo "## /var/lib/machines"
	ls -A /var/lib/machines
} >"$WORKDIR/after.txt"

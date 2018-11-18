#!/bin/bash
#
# Copyright 2018 Delphix
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

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." 1>&2
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Must specify a single live-build variant to run." 1>&2
	exit 1
fi

if [[ "$1" != "base" ]] && [[ ! -d "live-build/variants/$1" ]]; then
	echo "Invalid live-build variant specified: $1" 1>&2
	exit 1
fi

set -o errexit
set -o pipefail

#
# Allow the appliance user's password to be configured via this
# environment variable, but use a sane default if its missing.
#
export APPLIANCE_PASSWORD="${APPLIANCE_PASSWORD:-delphix}"

#
# We need to be careful to set xtrace after we set the USERNAME and
# PASSWORD variables above; otherwise, we could leak the values of the
# environment variables to stdout (and captured in CI logs, etc.).
#
set -o xtrace

if [[ "$1" == "base" ]]; then
	export APPLIANCE_VARIANT="base"
	cd "$TOP/live-build/base"
else
	export APPLIANCE_VARIANT="$1"
	cd "$TOP/live-build/variants/$1"
fi

#
# The ancillary repository contains all of the first-party Delphix
# packages that are required for live-build to operate properly.
#

aptly serve -config="$TOP/ancillary-repository/aptly.config" &
APTLY_SERVE_PID=$!

#
# We need to wait for the Aptly server to be ready before we proceed;
# this can take a few seconds, so we retry until it succeeds.
#
set +o errexit
attempts=0
while ! curl --output /dev/null --silent --head --fail \
	"http://localhost:8080/dists/bionic/Release"; do
	((attempts++))
	if [[ $attempts -gt 30 ]]; then
		echo "Timed out waiting for ancillary repository." 1>&2
		kill -9 $APTLY_SERVE_PID
		exit 1
	fi

	sleep 1
done
set -o errexit

lb config
lb build

kill -9 $APTLY_SERVE_PID

#
# On failure, the "lb build" command above doesn't actually return a
# non-zero exit code. This is problematic for users that rely on this
# return code to determine if the script failed or not. Thus, to
# workaround this limitation, we rely on a heuristic to try and
# determine if an error occured. We check for a specific file that's
# generated at the final stage of the build. If this file exists, then
# we assume the build succeeded; likewise, if it doesn't exist, we
# assume the build failed.
#
if [[ ! -f binary/SHA256SUMS ]]; then
	exit 1
fi

#
# The base variant doesn't produce any virtual machine artifacts, so we
# need to avoid the "mv" calls below.
#
if [[ "$APPLIANCE_VARIANT" == "base" ]]; then
	exit 0
fi

#
# After running the build successfully, it should have produced various
# virtual machine artifacts. We move these artifacts into a specific
# directory to make it easy for the artifacts to be consumed by the
# user (e.g. other software); this is most useful when multiple variants
# are built via a single call to "make" (e.g. using the "all" target).
#
for ext in ova qcow2 upgrade.tar.gz migration.tar.gz gcp.tar.gz vhdx vmdk; do
	if [[ -f "$APPLIANCE_VARIANT.$ext" ]]; then
		mv "$APPLIANCE_VARIANT.$ext" "$TOP/live-build/artifacts"
	fi
done

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

set -o errexit
set -o xtrace

TMP_DIRECTORY=$(mktemp -d -p . tmp.deps.XXXXXXXXXX)
pushd "$TMP_DIRECTORY" &>/dev/null

#
# Before we download the packages, we need to make sure our apt cache is
# up-to-date, or else we may not find the packages we're looking for.
#
apt-get update

#
# We use "dget" to download the packages as opposed to, for example,
# "apt-get download" so that the resultant filenames for the packages
# are compatible to be later served with "aptly serve". If we used
# "apt-get download" some packages would have "%3a" in their filename,
# which causes problems when attempting to download that package from
# the aptly served repository.
#
"$TOP"/scripts/list-deb-rdependencies.sh "$TOP"/*.deb | \
	xargs -n 1 -P 16 dget -dq

rm -rf ~/.aptly
aptly repo create -distribution=bionic -component=delphix seed-repository
aptly repo add seed-repository .
aptly repo add seed-repository "$TOP"/*.deb
aptly snapshot create seed-repository-snapshot from repo seed-repository
aptly publish snapshot -skip-signing seed-repository-snapshot

tar -czf "$TOP"/artifacts/seed-repository.tar.gz -C ~/.aptly .

popd &>/dev/null
rm -rf "$TMP_DIRECTORY"

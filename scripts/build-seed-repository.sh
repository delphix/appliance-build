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

rm -rf ~/.aptly
aptly repo create -distribution=bionic -component=delphix seed-repository

TMP_DIRECTORY=$(mktemp -d -p . tmp.deps.XXXXXXXXXX)
pushd "$TMP_DIRECTORY" &>/dev/null

apt-get update
"$TOP"/scripts/list-deb-rdependencies.sh "$TOP"/*.deb | xargs apt-get download

aptly repo add seed-repository .
aptly repo add seed-repository "$TOP"/*.deb

tar -czf "$TOP"/artifacts/seed-repository.tar.gz -C ~/.aptly .

popd &>/dev/null
rm -rf "$TMP_DIRECTORY"

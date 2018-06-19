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

#
# This script is intended to take a path or filename of a .deb package
# file, and output a list of all of that .deb package's direct and
# transitive dependencies; in other words, list that package's recursive
# dependencies, hence the "rdependencies" in this script's filename.
#

if [[ $# -ne 1 ]]; then
	echo "Must specify a single path to a .deb file." 1>&2
	exit 1
fi

DEB_PATH=$(readlink -f "$1")

if [[ ! -f "$DEB_PATH" ]]; then
	echo "Path to file is invalid: $DEB_PATH" 1>&2
	exit 1
fi

set -o errexit
set -o xtrace

TMP_DIRECTORY=$(mktemp -d -p . tmp.germinate.XXXXXXXXXX)
pushd "$TMP_DIRECTORY" &>/dev/null

mkdir -p seed/bionic
echo "dependencies:" >seed/bionic/STRUCTURE

dpkg -I "$DEB_PATH" |
	grep Depends |
	cut -d ':' -f 2 |
	tr -d '[:blank:]' |
	tr ',' '\n' |
	sed 's/^/ * /' >seed/bionic/dependencies

germinate -S seed -s bionic 1>&2

tail -n +3 dependencies |
	head -n -2 |
	cut -d '|' -f 1

popd &>/dev/null
rm -rf "$TMP_DIRECTORY"

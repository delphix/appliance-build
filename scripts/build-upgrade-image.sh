#!/bin/bash -x
#
# Copyright 2018-2020 Delphix
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

. "${BASH_SOURCE%/*}/common.sh"

function usage() {
	echo "$(basename "$0"): $*" >&2
	echo "Usage: $(basename "$0") <name>"
	exit 2
}

[[ -n "$TOP" ]] || die "must be run inside of the git repository"
[[ $# -gt 1 ]] && usage "too many arguments specified"
[[ $# -lt 1 ]] && usage "too few arguments specified"

"$TOP/scripts/aptly-repo-from-debs.sh" "$1" ||
	die "failed to generate Aptly repository from .deb files"

"$TOP/scripts/upgrade-image-from-aptly-repo.sh" "$1" ||
	die "failed to generate upgrade image from Aptly repository"

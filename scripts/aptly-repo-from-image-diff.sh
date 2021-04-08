#!/bin/bash -x
#
# Copyright 2020 Delphix
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
# This script is responsible for taking two upgrade images as input, and
# generating a new Aptly repository containing the set difference of
# these two images (i.e. A - B), which it stores at ~/.aptly/public.
# This new repository can then be used to generate a new upgrade image,
# by running the "upgrade-image-from-aptly-repo.sh" script.
#

. "${BASH_SOURCE%/*}/common.sh"

set -o pipefail

function cleanup() {
	[[ -n "$UNPACK_DIR" ]] && [[ -d "$UNPACK_DIR" ]] && rm -rf "$UNPACK_DIR"
}

function usage() {
	echo "$(basename "$0"): $*" >&2
	echo "Usage: $(basename "$0") <image A> <image B>"
	exit 2
}

function import_image_into_aptly() {
	local reponame="$1"
	local imagepath="$2"

	mkdir "$reponame" || die "'mkdir $reponame' failed"
	pushd "$reponame" &>/dev/null || die "'pushd $reponame' failed"

	tar -xf "$imagepath" || die "failed to extract image '$imagepath'"
	tar -xf payload.tar.gz || die "failed to extract payload"

	aptly repo create "$reponame" ||
		die "failed to create repository: '$reponame'"
	aptly repo add "$reponame" pool ||
		die "failed to add packages to repository: '$reponame'"

	popd &>/dev/null || die "'popd' failed"
	rm -rf "$reponame" || die "'rm -rf $reponame' failed"
}

trap cleanup EXIT

[[ $# -gt 2 ]] && usage "too many arguments specified"
[[ $# -lt 2 ]] && usage "too few arguments specified"

IMAGE_A_PATH=$(readlink -f "$1")
[[ -n "$IMAGE_A_PATH" ]] || die "unable to determine image A path"
[[ -f "$IMAGE_A_PATH" ]] || die "image path is not a file: '$IMAGE_A_PATH'"

IMAGE_B_PATH=$(readlink -f "$2")
[[ -n "$IMAGE_B_PATH" ]] || die "unable to determine image B path"
[[ -f "$IMAGE_B_PATH" ]] || die "image path is not a file: '$IMAGE_B_PATH'"

UNPACK_DIR=$(mktemp -d -p . -t diff.XXXXXXX)
[[ -d "$UNPACK_DIR" ]] || die "failed to create unpack directory '$UNPACK_DIR'"
pushd "$UNPACK_DIR" &>/dev/null || die "'pushd $UNPACK_DIR' failed"

rm -rf ~/.aptly
import_image_into_aptly "image-a" "$IMAGE_A_PATH"
import_image_into_aptly "image-b" "$IMAGE_B_PATH"

popd &>/dev/null || die "'popd' failed"

#
# The repository we wish to build is the "set difference" of image A and
# image B; i.e. A - B. To do this, we perform the following steps below:
#
# 1. Create a new empty repository
# 2. Add all packages from image A to this new repository
# 3. Remove any packages that're found in image B
#
# The result of this, is a new repository containing all packages from
# image A, that are not in image B; this new repository is stored in
# ~/.aptly/public, and this can then be used by other parts of the build
# system (e.g. "upgrade-image-from-aptly-repo.sh").
#

aptly repo create -distribution=bionic -component=delphix upgrade-repository ||
	die "failed to create repository: 'upgrade-repository'"
aptly repo search image-a | xargs aptly repo copy image-a upgrade-repository ||
	die "failed to copy packages to repository: 'upgrade-repository'"

#
# Here we're performing step 3 from the comment above, but since the
# "delphix-upgrade-verification" and "delphix-entire" packages are a bit
# different than most other packages on a Delphix appliance, we need to
# handle these packages uniquely here. Specifically, we want to ensure these
# packages are always contained in the resultant Aptly repository (even if
# the package is the same within both image A and image B), as each package
# is essential to the proper functioning of any Delphix appliance upgrade.
#
# The "delphix-upgrade-verification" package is used to perform upgrade
# specific logic (and verification) during the upgrade process, such that we
# can avoid common pitfalls that would result in the upgrade process
# failing. Without this package being contained in the repository (and thus,
# any upgrade image generated from the repository), the verification stage
# of upgrade would fail, leading to the entire upgrade process failing. For
# more details, see the "verify-jar" script within the "upgrade-scripts"
# directory.
#
# Additionally, the "delphix-entire" package is used by the upgrade logic to
# determine which packages constitute the Delphix version the appliance is
# transitioning to, and ensure all of those packages are upgraded (or
# downgraded) to the correct versions based on the information provided by
# this package. Without this package, the upgrade logic would fail, as it
# would not be able to determine what packages to upgrade (or downgrade).
# For more details, see the "execute" script within the "upgrade-scripts"
# directory.
#
aptly repo search image-b |
	grep -v "^delphix-upgrade-verification" |
	grep -v "^delphix-entire" |
	xargs aptly repo remove upgrade-repository ||
	die "failed to remove packages from repository: 'upgrade-repository'"

aptly publish repo -skip-contents -skip-signing upgrade-repository ||
	die "failed to publish repository: 'upgrade-repository'"

[[ -d ~/.aptly/public ]] || die "failed to generate aptly repository"

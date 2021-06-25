#!/bin/bash -ex
#
# Copyright 2021 Delphix
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
# This script creates a new package that stores build metadata for packages
# built by Delphix. It takes one argument: the path where the
# combined-packages artifacts have been downloaded.
#

. "${BASH_SOURCE%/*}/common.sh"

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Must specify the path of the combined-packages artifacts." 1>&2
	exit 1
fi

PKG_DIR="$1"
[[ -d "$PKG_DIR/packages" ]] ||
	die "$PKG_DIR must be a path to combined-packages artifacts."

#
# Build info files will be installed into /var/delphix-buildinfo on the
# Delphix appliance.
#
target="$TOP/build-info/var/delphix-buildinfo"
mkdir -p "$target"

#
# Copy build metadata for each package
#
mkdir "$target/packages"
cd "$PKG_DIR/packages"
for pkg in */; do
	pushd "$pkg" &>/dev/null
	mkdir "$target/packages/$pkg"
	for file in GIT_HASH BUILD_INFO PACKAGE_MIRROR_URL_MAIN PACKAGE_MIRROR_URL_SECONDARY metadata.json; do
		[[ -f "$file" ]] && cp "$file" "$target/packages/$pkg/"
	done
	popd &>/dev/null
done

cp "$PKG_DIR/COMPONENTS" "$target/packages/"
cp "$PKG_DIR/KERNEL_VERSIONS" "$target/packages/"

#
# Generate build metadata for appliance-build
#
mkdir "$target/appliance-build"
cd "$TOP"
git rev-parse HEAD >"$target/appliance-build/GIT_HASH"

function check_env() {
	#
	# When the job is ran manually for testing purposes, we do not expect
	# all environment to be set, so skip the env check.
	#
	[[ -n "$JENKINS_URL" ]] || return 0

	local val="${!1}"
	[[ -n "$val" ]] || die "check_env: $1 must be non-empty"
	return 0
}

check_env APPLIANCE_BUILD_GIT_URL
echo "$APPLIANCE_BUILD_GIT_URL" >"$target/appliance-build/GIT_URL"
check_env APPLIANCE_BUILD_GIT_BRANCH
echo "$APPLIANCE_BUILD_GIT_BRANCH" >"$target/appliance-build/GIT_BRANCH"
check_env DELPHIX_PACKAGE_MIRROR_MAIN
echo "$DELPHIX_PACKAGE_MIRROR_MAIN" >"$target/appliance-build/DELPHIX_PACKAGE_MIRROR_MAIN"
check_env DELPHIX_PACKAGE_MIRROR_SECONDARY
echo "$DELPHIX_PACKAGE_MIRROR_SECONDARY" >"$target/appliance-build/DELPHIX_PACKAGE_MIRROR_SECONDARY"
check_env AWS_S3_OUTPUT
echo "$AWS_S3_OUTPUT" >"$target/appliance-build/ARTIFACTS_S3_LOCATION"
check_env DELPHIX_APPLIANCE_VERSION
echo "$DELPHIX_APPLIANCE_VERSION" >"$target/appliance-build/DELPHIX_APPLIANCE_VERSION"

#
# Build the package
#
cd "$TOP/build-info"
#
# We include some random characters in the version string to avoid collisions
# with other build-info packages built for different platforms but included in
# the same upgrade image. The timestamp is insufficient here since the other
# platforms are built in parallel.
#
rnd="$(uuidgen | tr -d '-' | fold -w 8 | head -n 1)"
version="1.0.0-delphix-$(date '+%Y.%m.%d.%H.%M.%S')-$rnd"
dch --create --package delphix-build-info -v "$version" \
	"Automatically generated changelog entry."

dpkg-buildpackage -uc -us -b

mv ../delphix-build-info*deb "$PKG_DIR/packages/"

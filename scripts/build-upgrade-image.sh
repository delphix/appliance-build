#!/bin/bash -eux
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
# This script is intended to build an upgrade image that contains all of
# the packages needed to upgrade a particular variant of the appliance,
# whichever platform it is running on. The upgrade image is a tar
# archive whose primary component is an Aptly/APT repository containing
# a version of the delphix-entire package for each supported platform
# and all of its dependencies. This repository is created by taking and
# combining all the deb.tar.gz tarballs produced by live build for this
# variant (of which there will be one per supported platform).
#

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Must specify a single variant." 1>&2
	exit 1
fi

cd "$TOP/upgrade"
APPLIANCE_VARIANT=$1

rm -rf ~/.aptly
rm -rf debs
mkdir debs

#
# For upgrade images that we ship to customers, we will need to include
# the packages for every platform that we support. Building for every
# platform can be time-comsuming though, so for developer convenience,
# here we just take the artifacts from the live-build stage for whatever
# appliance versions were built (making sure that we built for at least
# one platform), and build an upgrade image from that.
#
LIVE_BUILD_OUTPUT_DIR="$TOP/live-build/build/artifacts"
if ! compgen -G "$LIVE_BUILD_OUTPUT_DIR/$APPLIANCE_VARIANT*.debs.tar.gz"; then
	echo "No live-build artifacts found for this variant" >&2
	exit 1
fi
for deb_tarball in "$LIVE_BUILD_OUTPUT_DIR/$APPLIANCE_VARIANT"*.debs.tar.gz; do
	tar xf "$deb_tarball" -C debs
done

# Generate an Aptly/APT repository
aptly repo create -distribution=bionic -component=delphix upgrade-repository
aptly repo add upgrade-repository debs
aptly publish repo -skip-contents -skip-signing upgrade-repository

# Include version information about this image.
VERSION=$(dpkg -f "$(find debs/ -name 'delphix-entire-*' | head -n 1)" version)
sed "s/@@VERSION@@/$VERSION/" <version.info.template >version.info

tar -I pigz -cf "$APPLIANCE_VARIANT.upgrade.tar.gz" version.info -C upgrade-scripts . -C ~/.aptly .

mv "$APPLIANCE_VARIANT.upgrade.tar.gz" "$TOP/build/artifacts"

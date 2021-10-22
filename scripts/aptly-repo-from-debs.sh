#!/bin/bash -ex
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

#
# This script is responsible for generating a new Aptly repository by
# taking and combining all of the deb.tar.gz tarballs produced by live
# build for this variant (of which there will be one per supported
# platform). The generated repository will be stored at ~/.aptly/public.
# This new repository can then be used to generate a new upgrade image,
# by running the "upgrade-image-from-aptly-repo.sh" script.
#

. "${BASH_SOURCE%/*}/common.sh"

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

#
# Download the delphix upgrade verification debian package, stored in the
# combined-packages bundle.
#
AWS_S3_URI_COMBINED_PACKAGES=$(resolve_s3_uri \
	"$AWS_S3_URI_COMBINED_PACKAGES" \
	"devops-gate/master/linux-pkg/${UPSTREAM_BRANCH}/combine-packages/post-push/latest")

WORK_DIRECTORY=$(mktemp -d -p "$TOP/upgrade" tmp.pkgs.XXXXXXXXXX)

download_combined_packages_artifacts "$AWS_S3_URI_COMBINED_PACKAGES" \
	"$WORK_DIRECTORY" upgrade-verify

extract_debs_into_dir "$WORK_DIRECTORY/packages/upgrade-verify" \
	"$TOP/upgrade/debs"

rm -rf "$WORK_DIRECTORY"

#
# Generate an Aptly/APT repository
#
aptly repo create -distribution=focal -component=delphix upgrade-repository
aptly repo add upgrade-repository debs
aptly publish repo -skip-contents -skip-signing upgrade-repository

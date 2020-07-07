#!/bin/bash -ex
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

. "${BASH_SOURCE%/*}/common.sh"

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
# Download the delphix upgrade verification debian package.
# Note, we always pull from the "master" build of the verification
# package, no matter what the UPSTREAM_BRANCH of the appliance is that
# we're building; this is intentional.
#

AWS_S3_URI_UPGRADE_VERIFICATION=$(resolve_s3_uri \
	"$AWS_S3_URI_UPGRADE_VERIFICATION" \
	"$AWS_S3_PREFIX_UPGRADE_VERIFICATION" \
	"devops-gate/master/upgrade-verify/master/post-push/release/latest")

download_delphix_s3_debs "$TOP/upgrade/debs" "$AWS_S3_URI_UPGRADE_VERIFICATION"

#
# Generate an Aptly/APT repository
#
aptly repo create -distribution=bionic -component=delphix upgrade-repository
aptly repo add upgrade-repository debs
aptly publish repo -skip-contents -skip-signing upgrade-repository

#
# Generate the "payload" of the upgrade image, which will contain the
# upgrade scripts, as well as the Aptly/APT repository. We generate this
# "payload" tarball as a way to limit the number of files that we need
# to checksum and store in "upgrade image" tarball itself. Rather than
# the "upgrade image" tarball containing all of the files for the upgrade
# scripts and APT repository, it'll only contain the "payload.tar.gz"
# file, and a few other miscellaneous metadata files.
#
# We need to limit the files contained in the 'upgrade image" tarball
# because the signing service that we use to sign the SHA256SUMS file
# below, has a relatively small limit on the size of the file that we
# can sign with it. Thus, we need the contents of the SHA256SUMS file to
# be realtively small (and that file's size grows linearly with the
# number of files contained in the "upgrade image" tarball).
#
tar -I pigz -cf "payload.tar.gz" -C upgrade-scripts . -C ~/.aptly/public .

cp version.info.template version.info

# Include version information about this image.
VERSION=$(dpkg -f "$(find debs/ -name 'delphix-entire-*' | head -n 1)" version)
sed -i "s/@@VERSION@@/$VERSION/" version.info

#
# On 6.0 versions, the appliance stack expects to find the file
# verification-version.info pre-upgrade. This necessitates the
# packaging of this file in the upgrade image along with version.info.
#
cp verification-version.info.template verification-version.info

# Include version information about this image.
VERIFICATION_VERSION=$(dpkg -f "$(find debs/ -name 'delphix-upgrade-verification*.deb' | head -n 1)" version)
sed -i "s/@@VERIFICATION_VERSION@@/$VERIFICATION_VERSION/" verification-version.info
sed -i "s/@@VERIFICATION_VERSION@@/$VERIFICATION_VERSION/" version.info

#
# If we're running the build manually, and these variables are not
# already set in the environment, we use an arbitrarily low falue to
# allow upgrading to the produce upgrade image from any version.
#

if [[ -n "$DELPHIX_UPGRADE_MINIMUM_VERSION" ]]; then
	sed -i \
		"s/@@MINIMUM_VERSION@@/$DELPHIX_UPGRADE_MINIMUM_VERSION/" \
		version.info
else
	sed -i "s/@@MINIMUM_VERSION@@/0.0.0.0/" version.info
fi

if [[ -n "$DELPHIX_UPGRADE_MINIMUM_REBOOT_OPTIONAL_VERSION" ]]; then
	sed -i \
		"s/@@MINIMUM_REBOOT_OPTIONAL_VERSION@@/$DELPHIX_UPGRADE_MINIMUM_REBOOT_OPTIONAL_VERSION/" \
		version.info
else
	sed -i "s/@@MINIMUM_REBOOT_OPTIONAL_VERSION@@/0.0.0.0/" version.info
fi

sha256sum payload.tar.gz version.info verification-version.info prepare >SHA256SUMS

#
# As a precaution, we disable "xtrace" so that we avoid exposing the
# DELPHIX_SIGNATURE_TOKEN environment variable contents to stdout.
#
set +o xtrace
if [[ -n "${DELPHIX_SIGNATURE_TOKEN:-}" ]] && [[ -n "${DELPHIX_SIGNATURE_URL:-}" ]]; then
	echo "{\"data\": \"$(base64 -w 0 SHA256SUMS)\"}" >sign-request.payload

	#
	# Here, we need to generate signature files for all of the appliance
	# versions that'll be allowed to upgrade from, using this upgrade
	# image. We rely on the user of this script to pass in this list
	# of versions; generally this will be some Jenkins automation.
	#
	for signature_version in $DELPHIX_SIGNATURE_VERSIONS; do
		curl -s -S -f -H "Content-Type: application/json" \
			-u "$DELPHIX_SIGNATURE_TOKEN" -d @sign-request.payload \
			"$DELPHIX_SIGNATURE_URL/upgrade/keyVersion/${signature_version}/sign" \
			>sign-request.response

		jq -r .signature <sign-request.response >signature.base64
		base64 -d signature.base64 >"SHA256SUMS.sig.${signature_version}"

		rm sign-request.response signature.base64
	done
fi
set -o xtrace

# shellcheck disable=SC2046
tar -cf "$APPLIANCE_VARIANT.upgrade.tar" \
	$(ls SHA256SUMS.sig.* 2>/dev/null) \
	SHA256SUMS \
	version.info \
	verification-version.info \
	prepare \
	payload.tar.gz

mv "$APPLIANCE_VARIANT.upgrade.tar" "$TOP/build/artifacts"

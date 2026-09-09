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

. "${BASH_SOURCE%/*}/common.sh"

#
# This script is intended to be used to build the "ancillary" repository
# that is used when we run live-build to build our artifacts. Prior to
# running live-build to build any of the appliance variants, this
# ancillary repository must be created using this script.
#
# The ancillary repository is a directory containing an Aptly/APT
# repository that can be used as the root directory to "aptly serve".
# Further, this repository will contain all of the "first-party"
# packages produced by Delphix, such that they can be easily installed
# (and/or downloaded) via the live-build environment with normal APT
# commands (e.g. apt install, apt download, etc).
#

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory." 2>&1
	exit 1
fi

set -o xtrace
set -o errexit
set -o pipefail

OUTPUT_DIR=$TOP/live-build/build/ancillary-repository

function build_ancillary_repository() {
	local pkg_directory="$1"

	rm -rf "$HOME/.aptly"
	aptly repo create \
		-distribution=noble -component=main ancillary-repository
	aptly repo add ancillary-repository "$pkg_directory"
	aptly publish repo -skip-contents -skip-signing ancillary-repository

	mkdir -p "$OUTPUT_DIR/.."
	rm -rf "$OUTPUT_DIR"
	mv "$HOME/.aptly" "$OUTPUT_DIR"
	cat >"$OUTPUT_DIR/aptly.config" <<-EOF
		{
		    "rootDir": "$OUTPUT_DIR"
		}
	EOF
}

#
# The packages produced by Delphix are stored in Amazon S3.
# Thus, in order to populate the ancillary repository with these
# packages, they must be downloaded from S3, so they can be then
# inserted into the Aptly repository.
#
# All the Delphix-built packages consumed by appliance-build are compiled by
# the combine-packages job. If a combine-packages URI is provided, fetch the
# packages from there, otherwise determine the latest combined-packages URI
# automatically.
#
AWS_S3_URI_COMBINED_PACKAGES=$(resolve_s3_uri "$AWS_S3_URI_COMBINED_PACKAGES")

mkdir -p "$TOP/build"
WORK_DIRECTORY=$(mktemp -d -p "$TOP/build" tmp.pkgs.XXXXXXXXXX)

#
# Download all package artifacts built by Delphix, which includes debs and
# metadata.
#
mkdir -p "$WORK_DIRECTORY/artifacts"
download_combined_packages_artifacts "$AWS_S3_URI_COMBINED_PACKAGES" \
	"$WORK_DIRECTORY/artifacts"

#
# The DCT packages are only installed by the DCT appliance variants, so only
# download them when a DCT variant is being built (signalled by the
# ancillaryRepository gradle task via DELPHIX_BUILD_DCT_VARIANT). This avoids
# wastefully downloading them for the many builds (external-standard,
# internal-dev, internal-qa, hyperscale, etc.) that never install them. When a
# DCT variant is built, AWS_S3_URI_DCT_PACKAGES (if set) still selects a
# specific build; otherwise download_dct_artifacts fetches the latest.
#
if [[ "$DELPHIX_BUILD_DCT_VARIANT" == "true" ]]; then
	download_dct_artifacts "$AWS_S3_URI_DCT_PACKAGES" "$WORK_DIRECTORY/artifacts"
else
	echo "Skipping DCT artifact download: no DCT variant is being built."
fi

#
# The hyperscale compliance packages are only installed by the hyperscale
# appliance variants, so only download them when a hyperscale variant is being
# built (signalled by the ancillaryRepository gradle task via
# DELPHIX_BUILD_HYPERSCALE_VARIANT). This avoids wastefully downloading them for
# the many builds (external-standard, internal-dev, internal-qa, etc.) that
# never install them. When a hyperscale variant is built,
# AWS_S3_URI_HYPERSCALE_COMPLIANCE_PACKAGES (if set) still selects a specific
# build; otherwise download_hyperscale_artifacts fetches the latest.
#
if [[ "$DELPHIX_BUILD_HYPERSCALE_VARIANT" == "true" ]]; then
	download_hyperscale_artifacts "$AWS_S3_URI_HYPERSCALE_COMPLIANCE_PACKAGES" \
		"$WORK_DIRECTORY/artifacts"
else
	echo "Skipping hyperscale artifact download: no hyperscale variant is being built."
fi

#
# AWS_S3_URI_UCF_PACKAGES is an optional external variable set by the
# devops-gate UCF pipeline; when it is unset, download_ucf_artifacts skips the
# download. It is not a typo of AWS_S3_URI_DCT_PACKAGES, so the SC2153
# misspelling warning below is a false positive and is disabled.
#
# shellcheck disable=SC2153
download_ucf_artifacts "$AWS_S3_URI_UCF_PACKAGES" "$WORK_DIRECTORY/artifacts"

#
# Create a delphix-build-info package from the build metadata of each
# package and of appliance-build itself and store it along with the other
# downloaded artifacts.
#
"$TOP"/scripts/create-build-info-package.sh "$WORK_DIRECTORY/artifacts"

#
# Find all debs and put them into a directory that will be fed into Aptly.
#
mkdir -p "$WORK_DIRECTORY/debs"
extract_debs_into_dir "$WORK_DIRECTORY/artifacts" "$WORK_DIRECTORY/debs"

#
# Build up our Aptly/APT ancillary repository. After this function
# completes, there should be a directory named "ancillary-repository" at
# the top level of the git repository, that can later be "aptly
# serve"-ed and consumed by live-build.
#
build_ancillary_repository "$WORK_DIRECTORY/debs"

#
# Syft and cyclonedx-cli are used to generate and validate the CycloneDX
# SBOM for each image (see the "95-generate-sbom.binary" live-build
# hook). They're consumed as .deb's from the ancillary repository, like
# every other first-party Delphix package, but unlike those they're
# build-host-only tooling: they're installed onto the build host here,
# and are never listed in any of live-build's chroot package lists, so
# they never end up inside the appliance image itself.
#
# They're installed here, rather than from run-live-build.sh, because
# the ancillary repository is built once and shared by every
# variant/platform combination in the build, whereas run-live-build.sh
# runs once per combination; there's no reason to reinstall this tooling
# for each of them. Installing directly from the .deb's that were just
# fed into Aptly also means this needs neither a running "aptly serve",
# nor any modification of the build host's APT sources configuration.
#
# Note that these are installed via "apt-get install <path>" rather than
# "dpkg -i <path>": delphix-cyclonedx-cli declares real dependencies
# (libicu, plus the usual shared library ones), and dpkg, unlike apt,
# won't resolve those. Passing apt a path rather than a package name
# still installs exactly the .deb we just built the repository from,
# while letting the build host's existing APT sources satisfy the
# dependencies.
#
for pkg in delphix-syft delphix-cyclonedx-cli; do
	deb=$(find "$WORK_DIRECTORY/debs" -maxdepth 1 -name "${pkg}_*.deb" |
		head -n 1)
	[[ -n "$deb" ]] ||
		die "Could not find a '$pkg' package in the ancillary repository."
	apt-get install -y --no-install-recommends "$deb"
done

rm -rf "$WORK_DIRECTORY"

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
		-distribution=bionic -component=main ancillary-repository
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
# Set UPSTREAM_BRANCH. This will determine which version of the linux package
# mirror is used.
#
if [[ -z "$UPSTREAM_PRODUCT_BRANCH" ]]; then
	echo "UPSTREAM_PRODUCT_BRANCH is not set."
	if ! source "$TOP/branch.config" 2>/dev/null; then
		echo "No branch.config file found in repo root."
		exit 1
	fi

	if [[ -z "$UPSTREAM_BRANCH" ]]; then
		echo "UPSTREAM_BRANCH parameter was not sourced from branch.config." \
			"Ensure branch.config is properly formatted with e.g." \
			"UPSTREAM_BRANCH=\"<upstream-product-branch>\""
		exit 1
	fi
	echo "Defaulting to branch $UPSTREAM_BRANCH set in branch.config."
else
	UPSTREAM_BRANCH="$UPSTREAM_PRODUCT_BRANCH"
fi
echo "Running with UPSTREAM_BRANCH set to ${UPSTREAM_BRANCH}"

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

AWS_S3_URI_COMBINED_PACKAGES=$(resolve_s3_uri \
	"$AWS_S3_URI_COMBINED_PACKAGES" \
	"devops-gate/master/linux-pkg/${UPSTREAM_BRANCH}/combine-packages/post-push/latest")

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

rm -rf "$WORK_DIRECTORY"

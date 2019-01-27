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
# This script downloads previously built vm artifacts from S3 and places
# them in live-build/build/artifacts/ as if they had been built by running
# 'gradle buildInternalDevAws', etc. This allows us to split up the
# live-build stage of the build between a number of machines, using
# parallelism to reduce build time, and then gather the artifacts for the
# stage where we build the upgrade image.
#

set -o xtrace
set -o errexit

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

function fetch_artifacts() {

	local tmp_dir

	#
	# S3 considers duplicate slashes significant, so put the URI in
	# a known state by removing the trailing slash if there is one.
	#
	local S3_URI="${1%/}"

	tmp_dir=$(mktemp -d -p "$TOP/build" livebuild_artifacts.XXXXXXXXXX)
	pushd "$tmp_dir" &>/dev/null

	debs_file=$(aws s3 ls "$S3_URI/" | awk '{ print $4 }' | grep 'debs.tar.gz')
	aws s3 cp --only-show-errors "$S3_URI/$debs_file" .
	aws s3 cp --only-show-errors "$S3_URI/SHA256SUMS" .

	sha256sum -c --strict <(grep "$debs_file" <SHA256SUMS)
	rm SHA256SUMS

	mv ./* "$TOP/live-build/build/artifacts/"

	popd &>/dev/null
	rm -rf "$tmp_dir"
}

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repository." 2>&1
	exit 1
fi

if [[ -z "$AWS_S3_URI_LIVEBUILD_ARTIFACTS" ]]; then
	echo "'AWS_S3_URI_LIVEBUILD_ARTIFACTS' must be set." 2>&1
	exit 1
fi

mkdir -p "$TOP/build"
for s3_uri in $AWS_S3_URI_LIVEBUILD_ARTIFACTS; do
	fetch_artifacts "$s3_uri"
done

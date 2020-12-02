#!/bin/bash
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

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

function resolve_s3_uri() {
	local pkg_uri="$1"
	local pkg_prefix="$2"
	local latest_subprefix="$3"

	local bucket="snapshot-de-images"
	local jenkinsid="jenkins-ops"
	local resolved_uri

	if [[ -n "$pkg_uri" ]]; then
		resolved_uri="$pkg_uri"
	elif [[ "$pkg_prefix" == s3* ]]; then
		resolved_uri="$pkg_prefix"
	elif [[ -n "$pkg_prefix" ]]; then
		resolved_uri="s3://$bucket/$pkg_prefix"
	elif [[ -n "$latest_subprefix" ]]; then
		aws s3 cp --quiet \
			"s3://$bucket/builds/$jenkinsid/$latest_subprefix" .
		resolved_uri="s3://$bucket/$(cat latest)"
		rm -f latest
	else
		echo "Invalid arguments provided to resolve_s3_uri()" 2>&1
		exit 1
	fi

	if aws s3 ls "$resolved_uri" &>/dev/null; then
		echo "$resolved_uri"
	else
		echo "'$resolved_uri' not found." 1>&2
		exit 1
	fi
}

function download_delphix_s3_debs() {
	local pkg_directory="$1"
	local S3_URI="$2"
	local tmp_directory

	tmp_directory=$(mktemp -d -p "$TOP/build" tmp.s3-debs.XXXXXXXXXX)
	pushd "$tmp_directory" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .
	sha256sum -c --strict SHA256SUMS

	mv ./*deb "$pkg_directory/"

	popd &>/dev/null
	rm -rf "$tmp_directory"
}

function download_delphix_s3_debs_multidir() {
	local pkg_directory="$1"
	local S3_URI="$2"
	local tmp_directory

	tmp_directory=$(mktemp -d -p "$TOP/build" tmp.s3-debs.XXXXXXXXXX)
	pushd "$tmp_directory" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .

	for subdir in */; do
		pushd "$subdir" &>/dev/null
		sha256sum -c --strict SHA256SUMS
		mv ./*deb "$pkg_directory/"
		popd &>/dev/null
	done

	popd &>/dev/null
	rm -rf "$tmp_directory"
}

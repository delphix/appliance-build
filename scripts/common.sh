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

# shellcheck disable=SC2034
TOP=$(git rev-parse --show-toplevel 2>/dev/null)

function die() {
	echo "$(basename "$0"): $*" >&2
	exit 2
}

function resolve_s3_uri() {
	local pkg_uri="$1"

	local resolved_uri

	if [[ -n "$pkg_uri" ]]; then
		resolved_uri="$pkg_uri"
	else
		#
		# Set UPSTREAM_BRANCH. This will determine which version of the linux package
		# mirror is used.
		#
		UPSTREAM_BRANCH=$(get_upstream_or_fail_if_unset) || exit 1
		echo "Running with UPSTREAM_BRANCH set to ${UPSTREAM_BRANCH}"
		local latest_subprefix="linux-pkg/${UPSTREAM_BRANCH}/combine-packages/post-push/latest"
		local bucket="snapshot-de-images"
		local jenkinsid="jenkins-ops"
		aws s3 cp --quiet \
			"s3://$bucket/builds/$jenkinsid/$latest_subprefix" .
		resolved_uri="s3://$bucket/$(cat latest)"
		rm -f latest
	fi

	if aws s3 ls "$resolved_uri" &>/dev/null; then
		echo "$resolved_uri"
	else
		echo "'$resolved_uri' not found." 1>&2
		exit 1
	fi
}

#
# Given an S3 URI pointing to combined-packages artifacts, download all of its
# artifacts to target directory. If a package name is passed as an argument,
# then only copy the artifacts for that package.
#
# When the combine-packages Jenkins job generates artifacts, it does not
# copy around the artifacts for individual packages. Rather, it creates a
# COMPONENTS file that has links to each package's artifacts.
#
# When appliance-build is ran via Jenkins, the Jenkins job copies the original
# combined-packages artifacts to a new S3 location, then dereferences the
# COMPONENTS file and copies all individual package artifacts into a
# "packages" directory created under that new S3 location. Jenkins then passes
# that combined-packages URI to live-build.
#
# Thus if a "packages" directory is found under the combined-packages S3 URI,
# we assume that the dereferencing has already been done and so we just sync
# the whole directory. Otherwise, we must dereference the COMPONENTS file here
# and fetch the artifacts for each package.
#
# Here are the files that are expected to be found after the download.
# <combined packages base directory>/
#   COMPONENTS
#   ... (some other metadata files)
#   packages/
#     package1/
#       ... (package 1 artifacts)
#     package2/
#       ... (package 2 artifacts)
#     ... (remaining packages' artifacts)
#
# shellcheck disable=SC2164
function download_combined_packages_artifacts() {
	local combined_pkgs_uri="$1"
	local target_dir="$2"
	local pkg="$3"

	pushd "$target_dir" &>/dev/null

	if [[ -n "$pkg" ]]; then
		aws s3 sync --exclude 'packages/*' --include "packages/$pkg/*" \
			--only-show-errors "$combined_pkgs_uri" .
	else
		aws s3 sync --only-show-errors "$combined_pkgs_uri" .
	fi

	if [[ -d packages ]]; then
		popd &>/dev/null
		return
	fi

	[[ -f COMPONENTS ]] || die "COMPONENTS file missing."
	mkdir packages
	pushd packages &>/dev/null

	local pkgname s3uri
	while read -r line; do
		pkgname=$(echo "$line" | cut -d: -f 1 | tr -d '[:space:]')
		s3uri=$(echo "$line" | cut -d: -f 2- | tr -d '[:space:]')
		[[ -n "$pkg" ]] && [[ "$pkg" != "$pkgname" ]] && continue
		mkdir "$pkgname"
		pushd "$pkgname" &>/dev/null
		aws s3 sync --only-show-errors "$s3uri" .
		sha256sum -c --strict SHA256SUMS
		popd &>/dev/null
	done <../COMPONENTS

	popd &>/dev/null
	popd &>/dev/null
}

#
# Find all .deb and .ddeb packages in source directory tree and move them
# to target directory.
#
function extract_debs_into_dir() {
	local source_dir="$1"
	local target_dir="$2"

	[[ -d "$target_dir" ]] ||
		die "'$target_dir' must be an existing directory"
	find "$source_dir" -name '*.deb' -exec mv {} "$target_dir" \;
	find "$source_dir" -name '*.ddeb' -exec mv {} "$target_dir" \;
}

function get_upstream_or_fail_if_unset() {
	if [[ -z "$UPSTREAM_PRODUCT_BRANCH" ]]; then
		local upstream_branch
		upstream_branch="$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" | cut -d'/' -f2-)"
		if [[ -z $upstream_branch ]]; then
			echo "ERROR: The currently checked out branch" >&2
			echo "  does not have an upstream branch configured. Set the" >&2
			echo "  upstream branch you plan to push to:" >&2
			echo "" >&2
			echo "    git branch --set-upstream-to=<upstream>" >&2
			echo "" >&2
			echo "  Then run this script again. '<upstream>' can be " >&2
			echo "  something like '6.0/stage'" >&2
			return 1
		else
			echo "$upstream_branch"
			return 0
		fi
	else
		echo "$UPSTREAM_PRODUCT_BRANCH"
	fi
}

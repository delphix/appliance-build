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

#
# The number of times an "aws s3 sync" is attempted before giving up, and the
# delay in seconds before the first retry. The delay doubles after every
# failed attempt.
#
S3_SYNC_ATTEMPTS=3
S3_SYNC_DELAY=5

#
# Run "aws s3 sync" with the given arguments, retrying it if it fails.
#
# The AWS CLI does not retry every transient failure on its own. A connection
# that is dropped mid-transfer surfaces as "An HTTP Client raised an unhandled
# exception: I/O operation on closed file.", which the CLI treats as fatal
# rather than retryable, so a single dropped connection fails the whole sync
# even though every other object was copied successfully. Raising max_attempts
# or setting retry_mode in the AWS config does not help, as that exception
# bypasses botocore's retry handling entirely.
#
# Retrying is always safe here because "aws s3 sync" is idempotent: it skips
# objects that are already present in the destination, so a retry only
# re-fetches whatever is still missing.
#
# The final attempt is run outside the loop so that its exit status propagates
# to the caller, which is running under "set -o errexit".
#
function s3_sync() {
	local attempt delay=$S3_SYNC_DELAY

	for ((attempt = 1; attempt < S3_SYNC_ATTEMPTS; attempt++)); do
		aws s3 sync "$@" && return 0
		echo "'aws s3 sync $*' failed (attempt $attempt of" \
			"$S3_SYNC_ATTEMPTS); retrying in ${delay}s." 1>&2
		sleep "$delay"
		delay=$((delay * 2))
	done

	aws s3 sync "$@"
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
		s3_sync --exclude 'packages/*' --include "packages/$pkg/*" \
			--only-show-errors "$combined_pkgs_uri" .
	else
		s3_sync --only-show-errors "$combined_pkgs_uri" .
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
		s3_sync --only-show-errors "$s3uri" .
		sha256sum -c --strict SHA256SUMS
		popd &>/dev/null
	done <../COMPONENTS

	popd &>/dev/null
	popd &>/dev/null
}

function download_dct_artifacts() {
	local dct_artifacts_uri="$1"
	local target_dir="$2"

	if [[ -z "$dct_artifacts_uri" ]]; then
		DCT_S3_DIR="s3://snapshot-de-images"
		DCT_LATEST_PREFIX="builds/jenkins-ops/dct/develop/post-push/latest"

		aws s3 cp "$DCT_S3_DIR/$DCT_LATEST_PREFIX" .

		DCT_PACKAGE_PREFIX=$(cat latest)
		rm -f latest

		dct_artifacts_uri="$DCT_S3_DIR/$DCT_PACKAGE_PREFIX"
	fi

	mkdir "$target_dir/dct"
	pushd "$target_dir/dct" &>/dev/null || exit 1

	s3_sync "$dct_artifacts_uri" .
	sha256sum -c SHA256SUMS

	popd &>/dev/null || exit 1
}

function download_ucf_artifacts() {
	local ucf_artifacts_uri="$1"
	local target_dir="$2"

	#
	# UCF is a new product line; unlike DCT/Hyperscale we do not infer
	# a "latest" S3 path. The caller (devops-gate ucf-engine-release
	# pipeline) must pass AWS_S3_URI_UCF_PACKAGES explicitly.
	#
	if [[ -z "$ucf_artifacts_uri" ]]; then
		echo "No AWS_S3_URI_UCF_PACKAGES set; skipping UCF artifact download." 1>&2
		return 0
	fi

	mkdir "$target_dir/ucf"
	pushd "$target_dir/ucf" &>/dev/null || exit 1

	#
	# The UCF bucket usually lives in a different AWS account than
	# Delphix's linux-build-publish IAM user. If UCF-specific credentials
	# are exposed via AWS_UCF_ACCESS_KEY_ID / AWS_UCF_SECRET_ACCESS_KEY,
	# use them for this sync; otherwise fall back to the ambient
	# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (which Delphix's pipeline
	# sets to linux-build-publish credentials).
	#
	if [[ -n "${AWS_UCF_ACCESS_KEY_ID:-}" && -n "${AWS_UCF_SECRET_ACCESS_KEY:-}" ]]; then
		(
			export AWS_ACCESS_KEY_ID="$AWS_UCF_ACCESS_KEY_ID"
			export AWS_SECRET_ACCESS_KEY="$AWS_UCF_SECRET_ACCESS_KEY"
			s3_sync "$ucf_artifacts_uri" .
		)
	else
		s3_sync "$ucf_artifacts_uri" .
	fi

	#
	# Verify the downloaded packages against the SHA256SUMS manifest
	# produced by the UCF build pipeline (cds-appliance build-deb.yml).
	# This is unconditional: a missing manifest means we cannot detect
	# package corruption, so fail the build — same as the DCT and
	# Hyperscale downloads above.
	#
	sha256sum -c SHA256SUMS

	popd &>/dev/null || exit 1
}

function download_hyperscale_artifacts() {
	local hyperscale_artifacts_uri="$1"
	local target_dir="$2"

	if [[ -z "$hyperscale_artifacts_uri" ]]; then
		HYPERSCALE_S3_DIR="s3://snapshot-de-images"
		HYPERSCALE_LATEST_PREFIX="builds/jenkins-masking/github/delphix/hyperscale-masking/build/debian-pkg/develop/latest"

		aws s3 cp "$HYPERSCALE_S3_DIR/$HYPERSCALE_LATEST_PREFIX" .

		HYPERSCALE_PACKAGE_PREFIX=$(cat latest)
		rm -f latest

		hyperscale_artifacts_uri="$HYPERSCALE_S3_DIR/$HYPERSCALE_PACKAGE_PREFIX"
	fi

	mkdir "$target_dir/hyperscale"
	pushd "$target_dir/hyperscale" &>/dev/null || exit 1

	s3_sync "$hyperscale_artifacts_uri" .
	sha256sum -c SHA256SUMS

	popd &>/dev/null || exit 1
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

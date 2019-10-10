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

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

set -o errexit
set -o xtrace

#
# When running this script interactively (e.g. from an interactive
# terminal session) we want to use the "-ti" options. But, if we use
# these options from a Jenkins job, the command will fail because there
# won't be a TTY available. Thus, we need to check to see if a TTY is
# available before we try to use the "-ti" options.
#
if tty -s; then
	DOCKER_RUN="docker run -ti"
else
	DOCKER_RUN="docker run"
fi

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

$DOCKER_RUN --rm \
	--privileged \
	--network host \
	--ipc "none" \
	--volume /dev:/dev \
	--env AWS_S3_PREFIX_VIRTUALIZATION \
	--env AWS_S3_PREFIX_MASKING \
	--env AWS_S3_PREFIX_USERLAND_PKGS \
	--env AWS_S3_PREFIX_KERNEL_PKGS \
	--env AWS_S3_URI_VIRTUALIZATION \
	--env AWS_S3_URI_MASKING \
	--env AWS_S3_URI_USERLAND_PKGS \
	--env AWS_S3_URI_KERNEL_PKGS \
	--env AWS_S3_URI_LIVEBUILD_ARTIFACTS \
	--env APPLIANCE_PASSWORD \
	--env AWS_ACCESS_KEY_ID \
	--env AWS_SECRET_ACCESS_KEY \
	--env DELPHIX_APPLIANCE_VERSION \
	--env DELPHIX_PACKAGE_MIRROR_MAIN \
	--env DELPHIX_PACKAGE_MIRROR_SECONDARY \
	--env DELPHIX_PLATFORMS \
	--env DELPHIX_SIGNATURE_URL \
	--env DELPHIX_SIGNATURE_TOKEN \
	--env DELPHIX_SIGNATURE_VERSIONS \
	--env DELPHIX_UPGRADE_MINIMUM_VERSION \
	--env DELPHIX_UPGRADE_MINIMUM_REBOOT_OPTIONAL_VERSION \
	--env UPSTREAM_BRANCH="$UPSTREAM_BRANCH" \
	--volume "$TOP:/opt/appliance-build" \
	--workdir "/opt/appliance-build" \
	appliance-build "$@"

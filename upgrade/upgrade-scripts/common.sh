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

# shellcheck disable=SC2034
UPDATE_DIR="/var/dlpx-update"
LOG_DIRECTORY="/var/log/delphix-upgrade"

function die() {
	echo "$(basename "$0"): $*" >&2
	exit 1
}

function warn() {
	echo "$(basename "$0"): $*" >&2
}

function get_image_path() {
	readlink -f "${BASH_SOURCE%/*}"
}

function get_image_version() {
	basename "$(get_image_path)"
}

function get_platform() {
	dpkg-query -Wf '${Package}' 'delphix-platform-*' |
		sed 's/delphix-platform-//'
}

function get_installed_version() {
	dpkg-query -Wf '${Version}' "delphix-entire-$(get_platform)"
}

function compare_versions() {
	dpkg --compare-versions "$@"
}

function report_progress() {
	#
	# Application stack depends on the format of the progress report for parsing.
	#
	echo "Progress increment: $(date +%T:%N%z), $1, $2"
}

function source_version_information() {
	local IMAGE_PATH="${IMAGE_PATH:-$(get_image_path)}"
	[[ -n "$IMAGE_PATH" ]] || die "failed to determine image path"

	local IMAGE_VERSION="${IMAGE_VERSION:-$(get_image_version)}"
	[[ -n "$IMAGE_VERSION" ]] || die "failed to determine image version"

	[[ -f "$IMAGE_PATH/version.info" ]] ||
		die "image for version '$IMAGE_VERSION' missing version.info"
	. "$IMAGE_PATH/version.info" ||
		die "failed to source version.info for version '$IMAGE_VERSION'"

	[[ -n "$VERSION" ]] || die "VERSION is empty"
	[[ -n "$MINIMUM_VERSION" ]] || die "MINIMUM_VERSION is empty"
	[[ -n "$MINIMUM_REBOOT_OPTIONAL_VERSION" ]] ||
		die "MINIMUM_REBOOT_OPTIONAL_VERSION is empty"
}

function verify_upgrade_is_allowed() {
	source_version_information

	local INSTALLED_VERSION
	INSTALLED_VERSION=$(get_installed_version)

	compare_versions \
		"$INSTALLED_VERSION" "ge" "$MINIMUM_VERSION" ||
		die "upgrade in-place is not allowed;" \
			"installed version ($INSTALLED_VERSION)" \
			"is less than minimum allowed version" \
			"($MINIMUM_VERSION)"
}

function is_upgrade_in_place_allowed() {
	source_version_information

	local INSTALLED_VERSION
	INSTALLED_VERSION=$(get_installed_version)

	compare_versions \
		"${INSTALLED_VERSION}" "ge" "${MINIMUM_REBOOT_OPTIONAL_VERSION}"
}

function verify_upgrade_in_place_is_allowed() {
	if ! is_upgrade_in_place_allowed; then
		die "upgrade in-place is not allowed for reboot required upgrade;" \
			"installed version ($INSTALLED_VERSION)" \
			"is less than minimum allowed version" \
			"($MINIMUM_REBOOT_OPTIONAL_VERSION)"
	fi
}

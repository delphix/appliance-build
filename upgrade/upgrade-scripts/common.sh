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
LOG_DIRECTORY="/var/tmp/delphix-upgrade"

#
# We embed information as dataset properties in our rootfs containers.
# These are the names of these properties.
#
# The values of each (respectively) represents the intial version of the
# delphix software that was installed in the given rootfs container, and
# the current version of the delphix software that is installed in the
# given rootfs container.
#
# These names should not be changed without heeding caution, since they
# represent part of the "on disk format" for our rootfs containers, and
# any changes may still need to be backwards compatible with these old
# names (due to existing systems still using the old names).
#
# Additionally, these names should remain consistent with the property
# names used when creating the appliance-build VM artifacts.
#
PROP_CURRENT_VERSION="com.delphix:current-version"
PROP_INITIAL_VERSION="com.delphix:initial-version"

#
# To better enable root cause analysis of any upgrade failures, we
# enable the "xtrace" feature here, and redirect that output to the
# system log. This way, we can easily obtain a trace of the execution
# path via the system log, which can be invaluable for any post-mortem
# analysis of a failure. Verbose logging is available in /var/log/syslog
# on the Delphix Engine
#
exec 4> >(logger -t "upgrade-scripts:$(basename "$0")" --id=$$)
BASH_XTRACEFD="4"
PS4='${BASH_SOURCE[0]}:${FUNCNAME[0]}:${LINENO[0]} '
set -o xtrace

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

function get_mounted_rootfs_container_dataset() {
	dirname "$(zfs list -Hpo name /)"
}

function get_mounted_rootfs_container_name() {
	basename "$(get_mounted_rootfs_container_dataset)"
}

function get_dataset_snapshots() {
	zfs list -d 1 -rt snapshot -Hpo name -s creation "$1"
}

function get_dataset_rollback_snapshot_name() {
	#
	# When the "execute" script is used to perform an in-place
	# upgrade, it will create a snapshot on all of the rootfs
	# container datasets that are modified/upgraded. The snapshot
	# name for all of these datasets should be the same, and it's
	# this snapshot name that we're trying to determine here.
	#
	get_dataset_snapshots "$1" |
		grep -E "^$1@execute-upgrade.[[:alnum:]]{7}$" |
		cut -d @ -f 2- |
		tail -n 1
}

function get_snapshot_clones() {
	zfs get clones -Hpo value "$1"
}

function get_current_version() {
	local DATASET
	DATASET="$(get_mounted_rootfs_container_dataset)"
	[[ -n "$DATASET" ]] ||
		die "could not determine mounted rootfs container dataset"

	local VERSION
	VERSION=$(zfs get -Hpo value "$PROP_CURRENT_VERSION" "$DATASET")
	[[ -n "$VERSION" && "$VERSION" != "-" ]] ||
		die "could not determine current version for '$DATASET'"

	echo "$VERSION"
}

function copy_dataset_property() {
	local PROP_NAME="$1"
	local SRC_DATASET="$2"
	local DST_DATASET="$3"
	local PROP_VALUE

	PROP_VALUE=$(zfs get -Hpo value "$PROP_NAME" "$SRC_DATASET")
	[[ -n "$PROP_VALUE" && "$PROP_VALUE" != "-" ]] ||
		die "failed to get property '$PROP_NAME' for '$SRC_DATASET'"

	zfs set "$PROP_NAME=$PROP_VALUE" "$DST_DATASET" ||
		die "failed to set property '$PROP_NAME=$PROP_VALUE' for '$DST_DATASET'"
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

	local CURRENT_VERSION
	CURRENT_VERSION=$(get_current_version) || die "failed to get version"

	compare_versions \
		"$CURRENT_VERSION" "ge" "$MINIMUM_VERSION" ||
		die "upgrade is not allowed;" \
			"installed version ($CURRENT_VERSION)" \
			"is not greater than minimum allowed version" \
			"($MINIMUM_VERSION)"
}

function is_upgrade_in_place_allowed() {
	source_version_information

	local CURRENT_VERSION
	CURRENT_VERSION=$(get_current_version) || die "failed to get version"

	compare_versions \
		"${CURRENT_VERSION}" "ge" "${MINIMUM_REBOOT_OPTIONAL_VERSION}"
}

function verify_upgrade_in_place_is_allowed() {
	local CURRENT_VERSION
	CURRENT_VERSION=$(get_current_version) || die "failed to get version"

	if ! is_upgrade_in_place_allowed; then
		die "upgrade in-place is not allowed for reboot required upgrade;" \
			"installed version ($CURRENT_VERSION)" \
			"is not greater than minimum allowed version" \
			"($MINIMUM_REBOOT_OPTIONAL_VERSION)"
	fi
}

function source_upgrade_properties() {
	. "$UPDATE_DIR/upgrade.properties" ||
		die "failed to source: '$UPDATE_DIR/upgrade.properties'"
}

function set_upgrade_property() {
	[[ -n "$1" ]] || die "upgrade property key is missing"
	[[ -n "$2" ]] || die "upgrade property value is missing"

	if [[ -f "$UPDATE_DIR/upgrade.properties" ]]; then
		sed -i "/^$1=.*$/d" "$UPDATE_DIR/upgrade.properties" ||
			die "failed to delete upgrade property: '$1'"
	fi

	echo "$1=$2" >>"$UPDATE_DIR/upgrade.properties" ||
		die "failed to set upgrade property: '$1=$2'"

	#
	# After setting the upgrade property above, we immediately read
	# in the file to ensure the new property didn't cause the file
	# to become unreadable.
	#
	source_upgrade_properties ||
		die "failed to read properties file after setting '$1=$2'"
}

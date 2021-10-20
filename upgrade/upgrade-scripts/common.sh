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
HOTFIX_PATH="/etc/hotfix"

#
# The virtualization service uses a different umask than the default. Thus to account for the
# fact that these scripts may be running with a non-default umask, we explicitly change it back
# to the default value here. This helps ensure any files and directories generated by these scripts,
# will be created with the correct permissions, regardless of the umask of the calling process.
#
umask 0022

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
PROP_HOTFIX_VERSION="com.delphix:hotfix-version"
PROP_MINIMUM_VERSION="com.delphix:minimum-version"

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

#
# In addition to redirecting the execution trace output to syslog (which
# is configured above), we also provide the following functions such
# that each script can enable and disable the redirection of their
# "stdout" and "stderr" to that same system log. This way, for the
# scripts that leverage these functions, we'll capture a trace of the
# script's execution, along with the output of the executed commands, in
# a single location (complete with timestamps for all executed commands
# and the commands' output).
#
# We don't automatically enable this redirection, since it would then
# mask usage and help messages that can be helpful when manually running
# the scripts. Thus, the intention is for each script to determine when
# it's most appropriate to enable and disable this redirection.
#

function start_stdout_redirect_to_system_log() {
	exec 5>&1
	exec 1>&4
}

function stop_stdout_redirect_to_system_log() {
	exec 1>&5
}

#
# This global variable is used to track which file descriptor
# corresponds to the script's stderr. This is relevant if a script
# redirects its stderr to the system log using the functions below, and
# helps us ensure errors (i.e. any calls to "die", "warn", etc.) will
# always be visible on stderr.
#
STDERR_FD=2

function start_stderr_redirect_to_system_log() {
	STDERR_FD=6
	eval "exec $STDERR_FD>&2"
	exec 2>&4
}

function stop_stderr_redirect_to_system_log() {
	exec 2>&$STDERR_FD
	STDERR_FD=2
}

function die() {
	echo "$(basename "$0"): $*" >&$STDERR_FD

	if [[ "$STDERR_FD" != "2" ]]; then
		#
		# If stderr is configured to be redirected to syslog, we
		# want to emit the error message to both, syslog and the
		# script's actual stderr file descriptor; this ensures
		# the message is sent to syslog too.
		#
		echo "$(basename "$0"): $*" >&2
	fi

	exit 1
}

function warn() {
	echo "$(basename "$0"): $*" >&$STDERR_FD

	if [[ "$STDERR_FD" != "2" ]]; then
		#
		# If stderr is configured to be redirected to syslog, we
		# want to emit the error message to both, syslog and the
		# script's actual stderr file descriptor; this ensures
		# the message is sent to syslog too.
		#
		echo "$(basename "$0"): $*" >&2
	fi
}

function get_image_path() {
	readlink -f "${BASH_SOURCE%/*}"
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

function get_version_property() {
	[[ -n "$1" ]] || die "version property not specified"

	local DATASET
	DATASET="$(get_mounted_rootfs_container_dataset)"
	[[ -n "$DATASET" ]] ||
		die "could not determine mounted rootfs container dataset"

	local VERSION
	VERSION=$(zfs get -Hpo value "$1" "$DATASET")
	[[ -n "$VERSION" && "$VERSION" != "-" ]] ||
		die "could not get version property '$1' for dataset '$DATASET'"

	echo "$VERSION"
}

function get_current_version() {
	get_version_property "$PROP_CURRENT_VERSION"
}

function get_hotfix_version() {
	get_version_property "$PROP_HOTFIX_VERSION"
}

function copy_required_dataset_property() {
	local PROP_NAME="$1"
	local SRC_DATASET="$2"
	local DST_DATASET="$3"
	local PROP_VALUE

	PROP_VALUE=$(zfs get -Hpo value "$PROP_NAME" "$SRC_DATASET")

	#
	# Unlike the "copy_optional_dataset_property" function, if the
	# property does not exist on the dataset, we return an error.
	# This is useful for properties that should always exist on the
	# dataset, in which case failing to retrieve the original value
	# should always be treated as an exception.
	#
	[[ -n "$PROP_VALUE" && "$PROP_VALUE" != "-" ]] ||
		die "failed to get property '$PROP_NAME' for '$SRC_DATASET'"

	zfs set "$PROP_NAME=$PROP_VALUE" "$DST_DATASET" ||
		die "failed to set property '$PROP_NAME=$PROP_VALUE' for '$DST_DATASET'"
}

function copy_optional_dataset_property() {
	local PROP_NAME="$1"
	local SRC_DATASET="$2"
	local DST_DATASET="$3"
	local PROP_VALUE

	#
	# Note, we only want to copy the dataset property when it's a
	# local value, rather than a potentially inherited value. Thus,
	# we use "-s local" to acheive this; i.e. with that set, if the
	# value is not local, no value will be returned.
	#
	PROP_VALUE=$(zfs get -s local -Hpo value "$PROP_NAME" "$SRC_DATASET")

	#
	# Unlike the "copy_required_dataset_property" function, if the
	# property does not exist on the dataset, we return without
	# copying the property. This is useful if the property needs to
	# be copied when it exists, and ignored otherwise.
	#
	[[ -n "$PROP_VALUE" && "$PROP_VALUE" != "-" ]] || return

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

	[[ -f "$IMAGE_PATH/version.info" ]] ||
		die "image missing version.info for $IMAGE_PATH"
	. "$IMAGE_PATH/version.info" ||
		die "failed to source version.info for $IMAGE_PATH"

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

function remove_upgrade_properties() {
	rm "$UPDATE_DIR/upgrade.properties" ||
		die "failed to remove: '$UPDATE_DIR/upgrade.properties'"
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

function apt_get() {
	DEBIAN_FRONTEND=noninteractive apt-get \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		"$@"
}

function xargs_apt_get() {
	DEBIAN_FRONTEND=noninteractive xargs apt-get \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		"$@"
}

function verify_upgrade_not_in_progress() {
	#
	# This function only works properly if the UPGRADE_TYPE variable
	# is not set prior to this function being called. Thus, to help
	# catch cases where this function is called incorrectly, we
	# verify the variable is empty before proceeding.
	#
	[[ -z "$UPGRADE_TYPE" ]] || die "UPGRADE_TYPE already set"

	. "$UPDATE_DIR/upgrade.properties" &>/dev/null
	[[ -z "$UPGRADE_TYPE" ]] || die "upgrade currently in-progress"
}

function mask_service() {
	local svc="$1"
	local container="$2"

	#
	# Note that masking should succeed even if service doesn't exist
	#
	if [[ -n "$container" ]]; then
		chroot "/var/lib/machines/$container" systemctl mask "$svc" ||
			die "failed to mask '$svc' in container '$container'"
	else
		systemctl mask "$svc" || die "failed to mask '$svc'"
	fi
}

function is_svc_masked_or_disabled() {
	local svc="$1"

	state=$(systemctl is-enabled "$svc")
	if [[ "$state" == masked || "$state" == disabled ]]; then
		return 0
	fi

	return 1
}

#
# This function has 2 tasks:
#  1. Fix/update the state of some services to be in line with what is expected
#     in this version of the appliance.
#  2. If we are doing a not-in-place upgrade, then migrate the state of the
#     services into the upgrade container.
#
# It can be called from 2 different contexts:
#  1. When creating upgrade container. In this case the container must be
#     passed as first argument.
#  2. When executing the in-place upgrade. In this case the function takes no
#     arguments.
#
function fix_and_migrate_services() {
	local container="$1"

	#
	# This function must be called from outside an upgrade container as it
	# uses the state of the services on the running system as the source of
	# truth. Since we want the logic in this script to apply both to an
	# upgrade container and to the running system (in case of an in-place
	# upgrade), we call it from two places: create_upgrade_container() and
	# the execute script. The former will apply this logic on a container
	# while the latter will apply this logic to the running system.
	#
	if systemd-detect-virt --container --quiet; then
		echo "fix_and_migrate_services: should not run inside container"
		return
	fi

	#
	# In versions prior to 6.0.13.0, snmpd.service was always enabled.
	# Disable (mask) it here if we detect that it should have been disabled.
	#
	if compare_versions "$(get_current_version)" lt "6.0.13.0"; then
		if [[ "$(systemctl is-enabled snmpd)" == enabled ]] &&
			! grep -q "Delphix" /etc/snmp/snmpd.conf; then
			mask_service snmpd "$container"
		fi
	fi

	#
	# The services listed below are either permanently disabled or can be
	# dynamically modified by the application(s) running on the appliance,
	# so we need to ensure we migrate the state of these services when
	# performing a not-in-place upgrade. Otherwise, we'd wind up with the
	# default state of these services on initial install, which is to stay
	# enabled and unmasked.
	#
	# If we are performing an in-place upgrade instead, then we want
	# to make sure that the state of those services conforms to the new
	# logic, which requires that the services are also masked when they
	# are disabled.
	#
	# The reason we want to mask services instead of just disabling them
	# is because when upgrading some of those packages, the services can
	# be automatically enabled by postinst scripts; this is especially
	# true for not-in-place upgrade, which creates a fresh debootstrap
	# image on which the new packages are installed for the first time.
	#
	# Finally, some of the services that are masked may be both masked
	# and disabled, while others would be only masked. This is okay
	# given that masked services will not run whether they are enabled
	# or disabled, and that the logic that unmasks them will also
	# enable them.
	#
	while read -r svc; do
		is_svc_masked_or_disabled "$svc" &&
			mask_service "$svc" "$container"
	done <<-EOF
		delphix-fluentd.service
		delphix-masking.service
		nfs-mountd.service
		nginx.service
		ntp.service
		postgresql.service
		rpc-statd.service
		rpcbind.service
		rpcbind.socket
		snmpd.service
		systemd-timesyncd.service
	EOF
}

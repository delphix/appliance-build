#!/bin/bash
#
# Copyright 2018, 2021 Delphix
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

check_env DELPHIX_PACKAGE_MIRROR_MAIN DELPHIX_PACKAGE_MIRROR_SECONDARY

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." 1>&2
	exit 1
fi

if [[ $# -ne 3 ]]; then
	echo "Must specify a single variant, a single platform, and a run " \
		"type (e.g. 'internal-minimal esx upgrade-artifacts')." 1>&2
	exit 1
fi

# Verify a valid run type is given
UPGRADE_RUN_TYPE="upgrade-artifacts"
VM_RUN_TYPE="vm-artifacts"
ALL_RUN_TYPE="all"
RUN_TYPES="$UPGRADE_RUN_TYPE|$VM_RUN_TYPE|$ALL_RUN_TYPE"

case "$3" in
"$UPGRADE_RUN_TYPE") ;;
"$VM_RUN_TYPE") ;;
"$ALL_RUN_TYPE") ;;
*)
	echo "Unknown run type '$3'. Must be one of <$RUN_TYPES>"
	exit 1
	;;
esac

set -o errexit
set -o pipefail

#
# Allow the appliance user's password to be configured via this
# environment variable, but use a sane default if its missing.
#
export APPLIANCE_PASSWORD="${APPLIANCE_PASSWORD:-delphix}"

#
# We need to be careful to set xtrace after we set the USERNAME and
# PASSWORD variables above; otherwise, we could leak the values of the
# environment variables to stdout (and captured in CI logs, etc.).
#
set -o xtrace

export APPLIANCE_VARIANT="$1"
export APPLIANCE_PLATFORM="$2"
export RUN_TYPE="$3"
export ARTIFACT_NAME="$APPLIANCE_VARIANT-$APPLIANCE_PLATFORM"

if [[ ! -d "$TOP/live-build/variants/$APPLIANCE_VARIANT" ]]; then
	echo "Invalid live-build variant specified: $1" 1>&2
	exit 1
fi

# Set up live-build environment
build_dir="$TOP/live-build/build/$ARTIFACT_NAME"
rm -rf "$build_dir"
mkdir -p "$build_dir"

cp -r "$TOP/live-build/auto" "$build_dir"

#
# Always copy over configuration hooks. If the run type is "all", then copy
# over all run type hooks. Otherwise, copy only the specified run type.
#
rsync -a --exclude="hooks" "$TOP/live-build/config" "$build_dir"
mkdir -p "$build_dir/config/hooks"
cp -r "$TOP/live-build/config/hooks/configuration/." "$build_dir/config/hooks"
if [[ "$RUN_TYPE" == "$ALL_RUN_TYPE" || "$RUN_TYPE" == "$VM_RUN_TYPE" ]]; then
	cp -r "$TOP/live-build/config/hooks/$VM_RUN_TYPE/." "$build_dir/config/hooks"
fi

sed "s/@@PLATFORM@@/$APPLIANCE_PLATFORM/" \
	<"$build_dir/config/package-lists/delphix-platform.list.chroot.in" \
	>"$build_dir/config/package-lists/delphix-platform.list.chroot"

if [[ -d "$TOP/live-build/variants/$APPLIANCE_VARIANT/package-lists" ]]; then
	for list in "$TOP/live-build/variants/$APPLIANCE_VARIANT/package-lists/"*; do
		[[ -f $list ]] || continue
		if [[ -f "$build_dir/config/package-lists/$(basename "$list")" ]]; then
			echo "Duplicate package list: $(basename "$list")" >&2
			exit 1
		fi
		cp "$list" "$build_dir/config/package-lists"
	done
fi

cp -r "$TOP/live-build/variants/$APPLIANCE_VARIANT/ansible" "$build_dir"

cd "$build_dir"

#
# The ancillary repository contains all of the first-party Delphix
# packages that are required for live-build to operate properly.
#

aptly serve -config="$TOP/live-build/build/ancillary-repository/aptly.config" &
APTLY_SERVE_PID=$!

#
# We need to wait for the Aptly server to be ready before we proceed;
# this can take a few seconds, so we retry until it succeeds.
#
set +o errexit
attempts=0
while ! curl --output /dev/null --silent --head --fail \
	"http://localhost:8080/dists/noble/Release"; do
	((attempts++))
	if [[ $attempts -gt 30 ]]; then
		echo "Timed out waiting for ancillary repository." 1>&2
		kill -9 $APTLY_SERVE_PID
		exit 1
	fi

	sleep 1
done

sed "s|@@URL@@|$DELPHIX_PACKAGE_MIRROR_SECONDARY|" \
	<config/archives/delphix-secondary-mirror.list.in \
	>config/archives/delphix-secondary-mirror.list

set -o errexit

lb config \
	--apt-recommends false \
	--parent-mirror-bootstrap "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-chroot "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-chroot-security "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-chroot-volatile "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-chroot-backports "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-binary "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-binary-security "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-binary-volatile "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--parent-mirror-binary-backports "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-bootstrap "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-chroot "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-chroot-security "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-chroot-volatile "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-chroot-backports "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-binary "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-binary-security "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-binary-volatile "$DELPHIX_PACKAGE_MIRROR_MAIN" \
	--mirror-binary-backports "$DELPHIX_PACKAGE_MIRROR_MAIN"

lb build

kill -9 $APTLY_SERVE_PID

#
# On failure, the "lb build" command above doesn't actually return a
# non-zero exit code. This is problematic for users that rely on this
# return code to determine if the script failed or not. Thus, to
# workaround this limitation, we rely on a heuristic to try and
# determine if an error occured. We check for a specific file that's
# generated at the final stage of the build. If this file exists, then
# we assume the build succeeded; likewise, if it doesn't exist, we
# assume the build failed.
#
if [[ ! -f binary/SHA256SUMS ]]; then
	exit 1
fi

case $APPLIANCE_PLATFORM in
aws) vm_artifact_ext=vmdk ;;
azure) vm_artifact_ext=vhdx ;;
esx) vm_artifact_ext=ova ;;
gcp) vm_artifact_ext=gcp.tar.gz ;;
hyperv) vm_artifact_ext=vhdx ;;
kvm) vm_artifact_ext=qcow2 ;;
oci) vm_artifact_ext=qcow2 ;;
*)
	echo "Invalid platform"
	exit 1
	;;
esac

#
# After running the build successfully, it should have produced various
# virtual machine artifacts. We move these artifacts into a specific
# directory to make it easy for the artifacts to be consumed by the
# user (e.g. other software); this is most useful when multiple variants
# are built via a single call to "make" (e.g. using the "all" target).
#
for ext in debs.tar.gz $vm_artifact_ext packages.list; do
	if [[ -f "$ARTIFACT_NAME.$ext" ]]; then
		mv "$ARTIFACT_NAME.$ext" "$TOP/live-build/build/artifacts/"
	fi
done

#
# Generate a per-image CycloneDX SBOM (best-effort — a failure must not block
# the build). Syft is run with the dpkg-db cataloger only against the chroot
# rootfs so the document is grounded in the authoritative installed-package set
# from /var/lib/dpkg/status rather than a heuristic filesystem scan.
#
# syft and check-jsonschema are provisioned on the build host by
# bootstrap/roles/appliance-build.bootstrap/tasks/main.yml. The CycloneDX
# schema file is pre-downloaded there to avoid a runtime network dependency.
#
# DELPHIX_APPLIANCE_VERSION is provided by the Gradle task environment.
#
(
	echo "[sbom] Scanning ${ARTIFACT_NAME} chroot rootfs (dpkg cataloger only) ..."
	syft scan "dir:${build_dir}/chroot" \
		--select-catalogers "dpkg" \
		--source-name "${ARTIFACT_NAME}" \
		--source-version "${DELPHIX_APPLIANCE_VERSION:-unknown}" \
		-o "cyclonedx-json=${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json"
	echo "[sbom] Wrote ${ARTIFACT_NAME}.cdx.json"
	echo "[sbom] Validating ${ARTIFACT_NAME}.cdx.json against CycloneDX 1.6 schema ..."
	/usr/local/lib/sbom-tools/bin/check-jsonschema \
		--schemafile "/usr/local/share/cyclonedx/bom-1.6.schema.json" \
		"${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json"
	echo "[sbom] Validation passed."
) || echo "[sbom] WARNING: CycloneDX SBOM generation failed for ${ARTIFACT_NAME}; the build continues without a SBOM." >&2

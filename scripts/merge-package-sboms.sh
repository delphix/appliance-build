#!/bin/bash
#
# Copyright 2026 Delphix
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
# Merge per-package CycloneDX SBOMs into an image's SBOM, in place.
#
# Usage: merge-package-sboms.sh <image-sbom> <package-sbom-dir>
#
# The image SBOM, produced by the "95-generate-sbom.binary" hook, lists every
# installed .deb as a flat pkg:deb component. linux-pkg publishes, beside each
# .deb of a package that bundles third-party code, an SBOM describing what is
# inside that .deb, named <deb-filename>.deb.cdx.json. For each of those whose
# .deb is installed in this image, this nests its components under the owning
# pkg:deb component. Every other component is left exactly as it was.
#
# The match is made on the SBOM's *filename*, not on its contents: the SBOM's
# metadata.component.name is the linux-pkg package name ("virtualization"),
# which is not the .deb's name ("delphix-virtualization"), and one package can
# emit several .debs. A Debian filename is <name>_<version>_<arch>.deb, and
# neither names nor versions may contain "_", so a three-way split on "_" is
# unambiguous. All three must match the installed component: a name match
# with a different version means the SBOM describes a different build of that
# .deb, and attributing its contents would be worse than leaving it flat.
#
# The version is accepted from either the filename or the SBOM's own
# metadata.component.version, because a .deb's filename can disagree with the
# Version: in its control file, which is what dpkg (and so the image SBOM)
# reports. windows-connector does this: windows-connector_2.4.dev.1_all.deb
# installs as version 1.0.0, and its SBOM records 1.0.0.
#
# Missing data degrades gracefully; corrupt data fails. An SBOM whose .deb is
# not installed (normal for variant-specific packages) is skipped, an
# installed .deb with no SBOM stays flat, an SBOM with no components is
# skipped rather than nesting an empty list, and a version mismatch is
# reported but not merged. An SBOM that is not valid JSON fails the script,
# since the result would ship to customers. See
# docs/specs/2026-10-01-sbom-image-merge-design.md.
#

. "${BASH_SOURCE%/*}/common.sh"

set -o errexit
set -o pipefail

[[ $# -eq 2 ]] || die "Usage: $0 <image-sbom> <package-sbom-dir>"

image_sbom="$1"
sbom_dir="$2"

[[ -f "$image_sbom" ]] || die "Image SBOM '$image_sbom' does not exist."

shopt -s nullglob
package_sboms=("$sbom_dir"/*.deb.cdx.json)
shopt -u nullglob

if [[ ${#package_sboms[@]} -eq 0 ]]; then
	echo "No package SBOMs in '$sbom_dir'; leaving $image_sbom unchanged."
	exit 0
fi

#
# The architecture of an installed .deb lives only in its purl, e.g.
# pkg:deb/ubuntu/delphix-zfs@2.4.99-...?arch=amd64&distro=ubuntu-24.04.
#
# shellcheck disable=SC2016
jq_arch='(try (.purl | capture("[?&]arch=(?<a>[^&]+)").a) catch null)'

#
# Each merge is written to a temporary file and moved over the image SBOM only
# once jq has succeeded, so a failure part-way leaves the previous, valid
# document in place. Remove that temporary file on any exit.
#
tmp=""
trap '[[ -n "$tmp" ]] && rm -f "$tmp"' EXIT

merged=0
empty=0
mismatched=0
absent=0

for package_sbom in "${package_sboms[@]}"; do
	base="${package_sbom##*/}"
	base="${base%.deb.cdx.json}"

	IFS=_ read -r name version arch extra <<<"$base"
	if [[ -z "$name" || -z "$version" || -z "$arch" || -n "$extra" ]]; then
		echo "WARNING: skipping '$package_sbom': not named" \
			"<name>_<version>_<arch>.deb.cdx.json."
		continue
	fi
	# An epoch's ":" is written as "%3a" in .deb filenames.
	version="${version//%3a/:}"

	jq -e . "$package_sbom" >/dev/null 2>&1 ||
		die "Package SBOM '$package_sbom' is not valid JSON."

	# Many .debs of a package carry none of its bundled content (most zfs
	# .debs, for instance); nesting an empty list under them adds nothing.
	count=$(jq '.components // [] | length' "$package_sbom")
	if [[ "$count" -eq 0 ]]; then
		empty=$((empty + 1))
		continue
	fi

	sbom_version=$(jq -r '.metadata.component.version // ""' "$package_sbom")

	#
	# Prints the installed version that matched (the filename's or the
	# SBOM's own), or "version-mismatch", or "absent".
	#
	match=$(jq -r --arg n "$name" --arg v "$version" --arg sv "$sbom_version" \
		--arg a "$arch" "
		[.components[] | select(.name == \$n)] as \$byname
		| [\$byname[]
		   | select($jq_arch == \$a and
		            (.version == \$v or (\$sv != \"\" and .version == \$sv)))
		   | .version] as \$hits
		| if (\$hits | length) > 0
		  then \"match:\" + \$hits[0]
		  elif (\$byname | length) > 0
		  then \"version-mismatch\"
		  else \"absent\"
		  end" "$image_sbom")

	case "$match" in
	match:*)
		installed="${match#match:}"
		tmp=$(mktemp "$image_sbom.XXXXXXXXXX")
		jq --arg n "$name" --arg v "$installed" --arg a "$arch" \
			--slurpfile pkg "$package_sbom" "
			(.components[]
			 | select(.name == \$n and .version == \$v and $jq_arch == \$a)
			 | .components) = \$pkg[0].components" \
			"$image_sbom" >"$tmp"
		mv "$tmp" "$image_sbom"
		tmp=""
		note=""
		if [[ "$installed" != "$version" ]]; then
			note=" (its filename says $version; matched on the SBOM's version)"
		fi
		echo "Merged $count component(s) under $name $installed ($arch)$note."
		merged=$((merged + 1))
		;;
	version-mismatch)
		wanted="$version"
		if [[ -n "$sbom_version" && "$sbom_version" != "$version" ]]; then
			wanted="$version or $sbom_version"
		fi
		echo "WARNING: not merging '$package_sbom': $name is installed," \
			"but not at version $wanted ($arch); the SBOM describes a" \
			"different build of it."
		mismatched=$((mismatched + 1))
		;;
	absent)
		absent=$((absent + 1))
		;;
	esac
done

echo "Package SBOMs: $merged merged, $empty with no components," \
	"$mismatched version mismatch(es), $absent for .debs not installed" \
	"in this image."

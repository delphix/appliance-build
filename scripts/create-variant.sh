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
# Default variant's playbook to use when creating the new variant
#
EXAMPLE_VARIANT=internal-minimal

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Must specify a variant name to create." 1>&2
	exit 1
fi

if [[ "$1" == "internal-"[a-z]* || "$1" == "external-"[a-z]* ]]; then

	if [[ -d "$TOP/live-build/variants/$1" ]]; then
		echo "variant specified ($1) already exists" 1>&2
		exit 1
	fi
else
	echo "Invalid variant naming convention: $1" 1>&2
	echo "Variants must start with either 'internal-<name>'" \
		"or 'external-<name>'" 1>&2
	exit 1
fi

set -o errexit
set -o xtrace

mkdir -p "$TOP/live-build/variants/$1"
mkdir -p "$TOP/live-build/variants/$1/ansible"
mkdir -p "$TOP/live-build/variants/$1/config"

ln -s ../../../misc/ansible-roles "$TOP/live-build/variants/$1/ansible/roles"
cp "$TOP/live-build/variants/$EXAMPLE_VARIANT/.gitignore" \
	"$TOP/live-build/variants/$1/"
cp "$TOP/live-build/variants/$EXAMPLE_VARIANT/ansible/playbook.yml" \
	"$TOP/live-build/variants/$1/ansible"

ln -s ../../../misc/live-build-hooks \
	"$TOP/live-build/variants/$1/config/hooks"

ln -s ../../misc/upgrade-scripts \
	"$TOP/live-build/variants/$1/upgrade-scripts"

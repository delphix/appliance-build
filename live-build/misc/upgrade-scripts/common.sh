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

UPDATE_DIR=${UPDATE_DIR:-"/var/dlpx-update"}
DROPBOX_DIR=${DROPBOX_DIR:-"/var/delphix/dropbox"}

function die() {
	echo "$(basename "$0"): $*" >&2
	exit 1
}

function get_image_path() {
	readlink -f "${BASH_SOURCE%/*}"
}

function get_image_version() {
	basename "$(get_image_path)"
}

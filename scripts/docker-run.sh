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

$DOCKER_RUN --rm \
	--privileged \
	--network host \
	--volume /dev:/dev \
	--env CI \
	--env TRAVIS \
	--env AWS_S3_BUCKET \
	--env AWS_S3_PREFIX_MASKING \
	--env AWS_S3_PREFIX_VIRTUALIZATION \
	--env AWS_S3_PREFIX_ZFS \
	--env APPLIANCE_PASSWORD \
	--env APPLIANCE_USERNAME \
	--env AWS_ACCESS_KEY_ID \
	--env AWS_SECRET_ACCESS_KEY \
	--volume "$TOP:/opt/appliance-build" \
	--workdir "/opt/appliance-build" \
	appliance-build "$@"

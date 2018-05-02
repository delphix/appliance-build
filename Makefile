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

ALL_VARIANTS = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -exec basename {} \;)
ALL_INTERNAL = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -name 'internal-*' -exec basename {} \;)
ALL_EXTERNAL = $(shell find live-build/variants -maxdepth 1 -mindepth 1 -name 'external-*' -exec basename {} \;)

all-variants: $(ALL_VARIANTS)
all-internal: $(ALL_INTERNAL)
all-external: $(ALL_EXTERNAL)

base:
	./scripts/run-live-build.sh $@

$(ALL_VARIANTS): base
	rsync -a --info=stats3 \
		--ignore-existing \
		--exclude config/hooks \
		live-build/$</ live-build/variants/$@/
	rm -f live-build/variants/$@/.build/binary_hooks
	rm -f live-build/variants/$@/.build/binary_checksums
	rm -f live-build/variants/$@/binary/SHA256SUMS
	./scripts/run-live-build.sh $@

shellcheck:
	shellcheck --exclude=SC1091 \
		$$(find scripts -type f -executable) \
		$$(find live-build/misc/live-build-hooks -type f -executable)

shfmt:
	shfmt -w $$(find scripts -type f -executable) \
		$$(find live-build/misc/live-build-hooks -type f -executable)

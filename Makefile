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

FINDEXEC.Darwin := -perm +111
FINDEXEC.Linux := -executable
FINDEXEC := $(FINDEXEC.$(shell uname -s))

SHELL_CHECKSTYLE_FILES = $(shell find scripts -type f $(FINDEXEC)) \
                $(shell find live-build/misc/live-build-hooks -type f $(FINDEXEC)) \
                $(shell find live-build/misc/upgrade-scripts -type f | grep -v README.md) \
                $(shell find live-build/misc/migration-scripts -type f)

.PHONY: \
	all-external \
	all-internal \
	all-variants \
	ansiblecheck \
	base \
	check \
	shellcheck \
	shfmtcheck \
	$(ALL_VARIANTS)

all-variants: $(ALL_VARIANTS)
all-internal: $(ALL_INTERNAL)
all-external: $(ALL_EXTERNAL)

base: ancillary-repository
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

ancillary-repository:
	./scripts/build-ancillary-repository.sh

shellcheck:
	shellcheck --exclude=SC1090,SC1091 $(SHELL_CHECKSTYLE_FILES)

#
# There doesn't appear to be a way to have "shfmt" return non-zero when
# it detects differences, so we have to be a little clever to accomplish
# this. Ultimately, we want "make" to fail when "shfmt" emits lines that
# need to be changed.
#
# When grep matches on lines emitted by "shfmt", it will return with a
# zero exit code. This tells us that "shfmt" did in fact detect changes
# that need to be made. When this occurs, we want "make" to fail, thus
# we have to invert grep's return code.
#
# This inversion also addresses the case where "shfmt" doesn't emit any
# lines. In this case, "grep" will return a non-zero exit code, so we
# invert this to cause "make" to succeed.
#
# Lastly, we want the lines emitted by "shfmt" to be user visible, so we
# leverage the fact that "grep" will emit any lines it matches on to
# stdout. This way, when lines are emitted from "shfmt", these
# problematic lines are conveyed to the user so they can be fixed.
#
shfmtcheck:
	! shfmt -d $(SHELL_CHECKSTYLE_FILES) | grep .

ansiblecheck:
	ansible-lint $$(find bootstrap live-build/variants -name playbook.yml)

check: shellcheck shfmtcheck ansiblecheck

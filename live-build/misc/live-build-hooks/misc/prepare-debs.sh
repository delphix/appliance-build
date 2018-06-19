#!/bin/bash -eu
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
# This script is meant to be called by the hook NN-package-repo.binary.
# It downloads all the debs installed in the image and stores them in /pkgrepo.
#

if [[ ! -d /pkgrepo ]]; then
	echo "/pkgrepo not found"
	exit 1
fi

cd /pkgrepo

for f in delphix-pkgs/*.deb; do
	dpkg-deb -W --showformat "\${Package}=\${Version}\\n" "$f"
done >delphix-packages.list

dpkg-query -Wf "\${Package}=\${Version}\\n" >all-packages.list

#
# comm requires lists to be sorted
#
sort -o all-packages.list all-packages.list
sort -o delphix-packages.list delphix-packages.list

#
# Check that all the debs in /pkgrepo/delphix-pkgs/ were installed
#
NOT_INSTALLED=$(comm -13 all-packages.list delphix-packages.list)
if [[ -n $NOT_INSTALLED ]]; then
	echo "The following delphix packages were not installed:"
	echo "$NOT_INSTALLED"
	exit 1
fi

#
# All the packages that aren't in delphix-packages.list were fetched
# through apt via various live-build stages. We pass them to apt to
# fetch all the debs
#
comm -23 all-packages.list delphix-packages.list >apt-packages.list

mkdir -p apt-pkgs

cd apt-pkgs
xargs -a ../apt-packages.list apt download

#
# We need to rename some files since some characters cause problems when
# accessed through http.
#
# More specifically, some packages have version '<num>:<some string>'.
# The problem is that ':' gets converted to %3a. Looking at the Ubuntu archive
# files, they do not store the '<num>:' part in the file names, so we drop
# it as well. The file names do not really matter as long as we do not have
# name collisions.
#
# For instance, bsdutils 1:2.31.1-0.4ubuntu3.1 is downloaded as:
#   bsdutils_1%3a2.31.1-0.4ubuntu3.1_amd64.deb, so we sanitize it to
#   bsdutils_2.31.1-0.4ubuntu3.1_amd64.deb
#
for f in *; do
	newf="${f/_*\%3a/_}"
	if [[ "$f" != "$newf" ]]; then
		mv "$f" "$newf"
		echo "renamed $f -> $newf"
	fi
done

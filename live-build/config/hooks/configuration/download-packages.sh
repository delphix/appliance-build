#!/bin/bash -eu

set -o pipefail

function download_packages() {
	echo "Downloading: $*"
	for _ in {1..5}; do
		apt-get download "$@" && return
		echo "Download failed, retrying."
		sleep 5
	done
	echo "Failed to download packages after 5 attempts. Aborting." >&2
	return 1
}

mkdir -p /packages
cd /packages

apt-get update

export -f download_packages
dpkg-query -Wf '${Package}=${Version}\n' |
	xargs -n 20 bash -c 'download_packages "$@"' _

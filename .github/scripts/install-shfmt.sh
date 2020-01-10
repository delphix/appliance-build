#!/bin/bash -ex

wget -nv -O /usr/local/bin/shfmt \
	https://github.com/mvdan/sh/releases/download/v2.4.0/shfmt_v2.4.0_linux_amd64
chmod +x /usr/local/bin/shfmt

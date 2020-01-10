#!/bin/bash -ex

git clone https://github.com/willthames/ansible-lint /opt/ansible-lint
cd /opt/ansible-lint
git checkout v3.4.21
git branch -D master

#
# GitHub Actions exposes some "debugging commands" that can be used to
# manipulate the environment of the job that's running. In this case, we
# use the "set-env" command to modify the environment of the job, to
# edit the PATH and PYTHONPATH global variables.
#
echo "::set-env name=PATH::${PATH}:/opt/ansible-lint/bin"
echo "::set-env name=PYTHONPATH::${PYTHONPATH}:/opt/ansible-lint/lib"

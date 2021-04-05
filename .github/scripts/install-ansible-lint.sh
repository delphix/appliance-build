#!/bin/bash -ex

sudo apt-get install python3-setuptools

git clone https://github.com/willthames/ansible-lint /opt/ansible-lint
cd /opt/ansible-lint
git checkout v5.0.6
git branch -D master
python3 -m pip install .

#
# GitHub Actions exposes the GITHUB_ENV file that can be used to
# manipulate the environment of the job that's running. In this case, we
# use it to modify the environment of the job, to edit the PATH and
# PYTHONPATH global variables.
#
echo "PATH=${PATH}:/opt/ansible-lint/bin" >> ${GITHUB_ENV}
echo "PYTHONPATH=${PYTHONPATH}:/opt/ansible-lint/lib" >> ${GITHUB_ENV}

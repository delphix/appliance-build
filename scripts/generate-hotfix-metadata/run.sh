#!/bin/bash

cd "${BASH_SOURCE%/*}"

function setup() {

	python3 -m pip install --user pipenv
	python3 -m pipenv install
}

# Credentials and URL information are provided via enviroment varibles set
# outside of this script
setup
python3 -m pipenv run python3 generate-hotfix-metadata.py -v $1 -o $2

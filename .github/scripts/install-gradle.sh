#!/bin/bash -ex

wget -nv https://services.gradle.org/distributions/gradle-5.1-bin.zip
sha256sum -c <<< '7506638a380092a0406364c79d6c87d03d23017fc25a5770379d1ce23c3fcd4d  gradle-5.1-bin.zip'
unzip -d /opt gradle-5.1-bin.zip
rm gradle-5.1-bin.zip

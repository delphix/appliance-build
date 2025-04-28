#!/bin/bash -ex

wget -nv https://services.gradle.org/distributions/gradle-8.14-bin.zip
sha256sum -c <<< '61ad310d3c7d3e5da131b76bbf22b5a4c0786e9d892dae8c1658d4b484de3caa  gradle-8.14-bin.zip'
unzip -d /opt gradle-8.14-bin.zip
rm gradle-8.14-bin.zip

#!/bin/bash -ex

wget -nv https://services.gradle.org/distributions/gradle-5.6.4-bin.zip
sha256sum -c <<< '1f3067073041bc44554d0efe5d402a33bc3d3c93cc39ab684f308586d732a80d  gradle-5.6.4-bin.zip'
unzip -d /opt gradle-5.6.4-bin.zip
rm gradle-5.6.4-bin.zip

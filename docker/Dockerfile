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

FROM ubuntu:bionic-20180426

MAINTAINER Prakash Surya <prakash.surya@delphix.com>

ENV DEBIAN_FRONTEND noninteractive
ENV HOME /root

WORKDIR /root
SHELL ["/bin/bash", "-c"]

RUN \
  apt-get update && \
  apt-get install -y software-properties-common && \
  apt-add-repository -y ppa:ansible/ansible && \
  apt-get update && \
  apt-get install -y \
      ansible \
      aptly \
      awscli \
      bc \
      coreutils \
      equivs \
      gdisk \
      git \
      java-package \
      jq \
      kpartx \
      libxt6 \
      livecd-rootfs \
      make \
      man \
      openjdk-8-jre-headless \
      pigz \
      rename \
      shellcheck \
      vim \
      zfsutils-linux && \
  rm -rf /var/lib/apt/lists/*

#
# Download and install Gradle. If downloading from Artifactory doesn't work,
# fall back to downloading from the official Gradle site. This allows us to
# build the Docker image when not on the Delphix network, which is useful for
# running style check via TravisCI.
#
RUN \
  ( wget -nv http://artifactory.delphix.com/artifactory/gradle-distributions/gradle-5.1-bin.zip || \
    wget -nv https://services.gradle.org/distributions/gradle-5.1-bin.zip ) && \
  sha256sum -c <<< '7506638a380092a0406364c79d6c87d03d23017fc25a5770379d1ce23c3fcd4d  gradle-5.1-bin.zip' && \
  mkdir /opt/gradle && \
  unzip -d /opt/gradle gradle-5.1-bin.zip && \
  rm gradle-5.1-bin.zip

RUN wget -nv -O /usr/local/bin/shfmt \
  https://github.com/mvdan/sh/releases/download/v2.4.0/shfmt_v2.4.0_linux_amd64 && \
  chmod +x /usr/local/bin/shfmt

RUN \
  git clone https://github.com/willthames/ansible-lint /opt/ansible-lint && \
  cd /opt/ansible-lint && \
  git checkout v3.4.21 && \
  git branch -D master
ENV PYTHONPATH="${PYTHONPATH}:/opt/ansible-lint/lib"
ENV PATH="${PATH}:/opt/ansible-lint/bin:/opt/gradle/gradle-5.1/bin"

#
# Set up the Gradle home directory to be located in a gitignored directory
# inside the repo. This way the cache of downloaded dependencies is preserved
# when the container running a build is destroyed.
#
ENV GRADLE_USER_HOME=/opt/appliance-build/.gradleUserHome

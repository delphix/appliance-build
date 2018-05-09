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

RUN \
  apt-get update && \
  apt-get install -y software-properties-common && \
  apt-add-repository -y ppa:ansible/ansible && \
  apt-get update && \
  apt-get install -y \
      ansible \
      livecd-rootfs \
      zfsutils-linux \
      awscli \
      coreutils \
      gdisk \
      git \
      jq \
      kpartx \
      make \
      man \
      shellcheck \
      vim && \
  rm -rf /var/lib/apt/lists/*

RUN wget -nv -O /usr/local/bin/shfmt \
  https://github.com/mvdan/sh/releases/download/v2.3.0/shfmt_v2.3.0_linux_amd64 && \
  chmod +x /usr/local/bin/shfmt

RUN \
  git clone https://github.com/willthames/ansible-lint /opt/ansible-lint && \
  cd /opt/ansible-lint && \
  git checkout v3.4.21 && \
  git branch -D master
ENV PYTHONPATH="${PYTHONPATH}:/opt/ansible-lint/lib"
ENV PATH="${PATH}:/opt/ansible-lint/bin"

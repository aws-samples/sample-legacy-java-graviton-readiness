#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Init container of the cgroup lab Job (mounted from the ConfigMap at /src): downloads the JDK
# tarball, checks its SHA-256, extracts it into /work/jdk and compiles the probes with the
# JDK's own javac into /work/classes. Environment: JDK_URL, JDK_SHA256.
set -euo pipefail
: "${JDK_URL:?}" "${JDK_SHA256:?}"
case "$JDK_URL" in https://*) ;; *) echo "JDK_URL must use https" >&2; exit 1 ;; esac
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --retry 3 --connect-timeout 30 -o /work/jdk.tar.gz "$JDK_URL"
printf '%s  %s\n' "$JDK_SHA256" /work/jdk.tar.gz | sha256sum -c -
python3 /src/extract_jdk.py /work/jdk.tar.gz /work/jdk
rm -f /work/jdk.tar.gz
mkdir -p /work/classes
/work/jdk/bin/javac -nowarn -d /work/classes /src/ContainerProbe.java /src/AllocPressure.java \
  /src/ThreadFootprint.java
echo "JDK ready: $(/work/jdk/bin/java -version 2>&1 | head -n 1)"

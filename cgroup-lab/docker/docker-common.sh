#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Helpers shared by run-docker-matrix.sh and run-thread-matrix.sh. Source this file after
# lib/common.sh; do not run it.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

DRY_RUN=0
RUN_TIMEOUT=900
RUN_COUNTER=0

# require_linux_docker: the labs measure the Linux kernel's cgroups, so they run only on a
# Linux host with a working docker daemon.
require_linux_docker() {
  [ "$(uname -s)" = Linux ] || die "this lab runs on a Linux host (use --dry-run to print the commands)"
  require_cmd docker timeout
  docker info >/dev/null 2>&1 || die "docker info failed: start docker and run as a user that may use it"
}

# compile_probes JDK_DIR SRC_DIR DEST: compiles the probe sources with the JDK's own javac
# and makes the classes readable for the container user.
compile_probes() {
  mkdir -p "$3"
  "$1/bin/javac" -nowarn -d "$3" "$2"/*.java >"$3.javac.txt" 2>&1 ||
    die "javac of $1 failed: $(cat "$3.javac.txt")"
  chmod -R a+rX "$3"
}

# container_args JDK_DIR CLASSES: the docker run options common to every run: no network,
# read-only root file system, non-root user, no capabilities, JDK and classes read-only.
container_args() {
  printf '%s\n' --network none --read-only --tmpfs /tmp:rw,size=64m \
    --user "$LAB_UID:$LAB_UID" --cap-drop ALL --security-opt no-new-privileges \
    -v "$1:/jdk:ro" -v "$2:/probe:ro"
}

# show_cmd ARGS...: prints a command line for --dry-run.
show_cmd() {
  local a out=""
  for a in "$@"; do out="$out ${a}"; done
  printf '+%s\n' "$out"
}

# docker_run NAME OUTFILE ERRFILE ARGS...: runs "docker run --name NAME ARGS" with a
# timeout, stores the inspect output next to OUTFILE, removes the container, and sets
# LAST_RC to the exit code of docker run. In dry-run mode only prints the command.
LAST_RC=0
docker_run() {
  local name="$1" out="$2" err="$3" dir
  shift 3
  LAST_RC=0
  if [ "$DRY_RUN" = 1 ]; then
    show_cmd docker run --name "$name" "$@"
    return 0
  fi
  dir="$(dirname "$out")"
  timeout "$RUN_TIMEOUT" docker run --name "$name" "$@" >"$out" 2>"$err" || LAST_RC=$?
  if [ "$LAST_RC" -eq 124 ]; then
    docker kill "$name" >/dev/null 2>&1 || true
    printf 'timed out after %s s\n' "$RUN_TIMEOUT" >>"$err"
  fi
  docker inspect "$name" >"$dir/docker-inspect.json" 2>/dev/null || printf '[]\n' >"$dir/docker-inspect.json"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# docker_quick OUTFILE ARGS...: "docker run --rm ARGS" with stdout and stderr in OUTFILE.
docker_quick() {
  local out="$1"
  shift
  if [ "$DRY_RUN" = 1 ]; then
    show_cmd docker run --rm "$@"
    return 0
  fi
  timeout "$RUN_TIMEOUT" docker run --rm "$@" >"$out" 2>&1 || true
}

# next_name: sets CONTAINER_NAME to a new container name for this script run.
CONTAINER_NAME=""
next_name() {
  RUN_COUNTER=$((RUN_COUNTER + 1))
  CONTAINER_NAME="jvmlab-$$-$RUN_COUNTER"
}

# epoch_ms: milliseconds since the epoch (GNU date), or seconds * 1000 elsewhere.
epoch_ms() {
  local t
  t="$(date +%s%3N 2>/dev/null)"
  case "$t" in
    *N | "") printf '%s000' "$(date +%s)" ;;
    *) printf '%s' "$t" ;;
  esac
}

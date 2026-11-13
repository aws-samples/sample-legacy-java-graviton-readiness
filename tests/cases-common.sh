#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Test cases for every script (help, unknown flags) and for lib/common.sh. Sourced by
# tests/run-tests.sh.

# Scripts with a command-line interface (sourced helpers and in-pod scripts excluded).
cli_scripts() {
  (cd "$REPO_DIR" && find lib jdk-matrix cgroup-lab infra -name '*.sh' \
    ! -name common.sh ! -name docker-common.sh ! -name 'pod-*.sh' | LC_ALL=C sort)
}

test_all_help() {
  local s n=0
  for s in $(cli_scripts); do
    run_script "$s" --help
    assert_exit 0
    assert_contains "Usage:"
    n=$((n + 1))
  done
  [ "$n" -ge 15 ] || fail "expected at least 15 scripts, found $n"
  assert_not_called "aws "
}

test_all_unknown_flag() {
  local s
  for s in $(cli_scripts); do
    run_script "$s" --bogus
    assert_exit 2
    assert_contains "unknown argument '--bogus'"
  done
  assert_not_called "aws "
}

# validator_rc FUNCTION VALUE: exit code of the validator in a subshell.
validator_rc() {
  local rc=0
  (
    # shellcheck source=/dev/null
    . "$REPO_DIR/lib/common.sh"
    "$1" "$2"
  ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

test_common_validators() {
  local v
  for v in "validate_owner example-owner" "validate_run_id run-20261103" "validate_jdk_id corretto-8.372.07.1" \
    "validate_jdk_id temurin-8u372-b07" "validate_host_label c8g-g1" "validate_region us-east-1" \
    "validate_instance_id i-0123456789abcdef0" "validate_docker_flag --memory=1g" \
    "validate_docker_flag --cpuset-cpus=0-1" "validate_jvm_flag -Xmx768m" \
    "validate_jvm_flag -XX:MaxRAMPercentage=75" "validate_jvm_flag -XX:-UseContainerSupport" \
    "validate_image public.ecr.aws/amazonlinux/amazonlinux:2023"; do
    # shellcheck disable=SC2086  # function name and value, split on purpose
    [ "$(validator_rc $v)" = 0 ] || fail "rejected: $v"
  done
  for v in "validate_owner Bad_Owner" "validate_owner a;b" "validate_run_id -bad" "validate_run_id UPPER" \
    "validate_jdk_id zulu-8" "validate_jdk_id corretto-8/../x" "validate_host_label C9G" \
    "validate_region cn-north-1" "validate_region us-gov-west-1" "validate_instance_id i-xyz" \
    "validate_docker_flag --privileged" "validate_docker_flag --memory=1g;id" \
    "validate_jvm_flag -javaagent:x.jar" "validate_jvm_flag -XX:OnError=sh" "validate_jvm_flag -Dx=y" \
    "validate_image Bad/Image"; do
    # shellcheck disable=SC2086  # function name and value, split on purpose
    [ "$(validator_rc $v)" = 2 ] || fail "accepted: $v"
  done
}

test_common_cgroup_version() {
  local v1 v2
  v2="$( . "$REPO_DIR/lib/common.sh"; cgroup_version "$FIXTURES/mountinfo-cgroup2.txt")"
  v1="$( . "$REPO_DIR/lib/common.sh"; cgroup_version "$FIXTURES/mountinfo-cgroup1.txt")"
  [ "$v2" = v2 ] || fail "cgroup2 fixture detected as $v2"
  [ "$v1" = v1 ] || fail "cgroup1 fixture detected as $v1"
}

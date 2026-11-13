#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Shared constants and helpers for the scripts in this repository. Source this file; do not
# run it. Compatible with bash 3.2 (the bash that ships with macOS).
# shellcheck disable=SC2034  # constants are used by the scripts that source this file

# Every AWS resource the scripts create carries these tags. Cleanup deletes only resources
# that carry the project tag and the run-id tag of the run.
SAMPLE_TAG_KEY="project"
SAMPLE_TAG_VALUE="sample-legacy-java-graviton-readiness"
OWNER_TAG_KEY="owner"
RUN_ID_TAG_KEY="run-id"
# Prefix of the names of the S3 bucket, IAM role, instance profile and security group.
NAME_PREFIX="legacy-java-graviton"
# Container image used by the docker and Kubernetes labs: the multi-arch index of
# public.ecr.aws/amazonlinux/amazonlinux:2023, pinned by digest (resolved 2026-11-03).
DEFAULT_IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:381352c430f36d8aa6b8b670de06e7e4e5642fe0cb9dbd463bb8d1e79aefc0c7"
# Non-root user that runs the JVM inside containers.
LAB_UID="10001"

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
JDK_CATALOG="${JDK_CATALOG:-$COMMON_DIR/jdks.csv}"

ASSUME_YES=0
TMP_WORK=""
EXIT_HOOK=""
AWS_OUT=""

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'ERROR: %s\n' "$*" >&2
  printf 'Run %s --help for usage.\n' "${SCRIPT_NAME:-$0}" >&2
  exit 2
}

# need_arg FLAG [VALUE...]: called as need_arg "$@" while parsing; FLAG needs a value.
need_arg() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    usage_error "$1 needs a value"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# Temporary directory (honors TMPDIR) and exit handling. EXIT_HOOK names an optional
# function that runs first on exit, for example to restore a kernel setting.
_on_exit() {
  if [ -n "$EXIT_HOOK" ]; then
    "$EXIT_HOOK" || true
  fi
  if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
    rm -rf -- "$TMP_WORK"
  fi
}
init_tmpdir() {
  TMP_WORK="$(mktemp -d)" || die "cannot create a temporary directory"
  trap _on_exit EXIT
  trap 'exit 130' INT TERM
}

# ---- validators (exit 2 on invalid input) -------------------------------------------------
_matches() {
  local value="$1" re="$2"
  [[ $value =~ $re ]]
}

validate_region() {
  case "$1" in
    cn-* | us-gov-* | eusc-*)
      usage_error "Region $1 is not supported: this sample supports the aws partition only"
      ;;
  esac
  _matches "$1" '^[a-z]{2}(-[a-z]+)+-[0-9]+$' ||
    usage_error "invalid --region '$1' (expected a Region code such as us-east-1)"
}

validate_profile() {
  _matches "$1" '^[A-Za-z0-9_.@+-]{1,64}$' || usage_error "invalid --profile '$1'"
}

# Tag value for the owner tag: lower-case letters, digits, dot, underscore and hyphen.
validate_owner() {
  _matches "$1" '^[a-z0-9._-]{1,64}$' ||
    usage_error "invalid --owner '$1' (1 to 64 characters: a-z 0-9 . _ -)"
}

# The run ID is part of the S3 bucket name, so it follows the bucket naming rules.
validate_run_id() {
  _matches "$1" '^[a-z0-9][a-z0-9-]{1,29}[a-z0-9]$' ||
    usage_error "invalid --run-id '$1' (3 to 31 characters: a-z 0-9 -, not starting or ending with -)"
}

validate_k8s_version() {
  _matches "$1" '^1\.[0-9]{2}$' ||
    usage_error "invalid --k8s-version '$1' (expected a Kubernetes minor version such as 1.34)"
}

validate_cluster_name() {
  _matches "$1" '^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$' || usage_error "invalid --cluster-name '$1'"
}

validate_instance_type() {
  _matches "$1" '^[a-z][a-z0-9-]*\.[a-z0-9]+$' || usage_error "invalid instance type '$1'"
}

validate_instance_id() {
  _matches "$1" '^i-[0-9a-f]{8,17}$' || usage_error "invalid --instance-id '$1'"
}

# JDK IDs are directory names, for example corretto-8.372.07.1 or temurin-8u372-b07.
validate_jdk_id() {
  _matches "$1" '^(corretto|temurin)-[0-9][0-9a-z.+-]{2,30}$' || usage_error "invalid JDK ID '$1'"
}

validate_jdk_arch() {
  case "$1" in
    aarch64 | x64) ;;
    *) usage_error "invalid --arch '$1' (supported: aarch64, x64, auto)" ;;
  esac
}

# Host labels name result directories, for example c9g or c8i-g1.
validate_host_label() {
  _matches "$1" '^[a-z0-9][a-z0-9_-]{0,31}$' || usage_error "invalid --host-label '$1'"
}

# Container image reference: registry/repository[:tag][@sha256:digest].
validate_image() {
  _matches "$1" '^[a-z0-9][a-z0-9./_-]*(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?$' ||
    usage_error "invalid --image '$1'"
}

validate_cidr() {
  local ip prefix rest octet _
  _matches "$1" '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' ||
    usage_error "invalid CIDR '$1' (expected an IPv4 CIDR such as 203.0.113.10/32)"
  ip="${1%/*}"
  prefix="${1#*/}"
  [ "$prefix" -le 32 ] || usage_error "invalid CIDR prefix in '$1'"
  rest="$ip"
  for _ in 1 2 3 4; do
    octet="${rest%%.*}"
    rest="${rest#*.}"
    [ "$octet" -le 255 ] || usage_error "invalid CIDR '$1'"
  done
}

# Resource flags that the docker lab passes to docker run (from configs-docker.csv).
validate_docker_flag() {
  _matches "$1" '^--(memory|memory-swap|cpus|cpuset-cpus|cpu-shares)=[0-9][0-9a-z.,-]*$' ||
    usage_error "unsupported docker flag '$1'"
}

# JVM flags that the labs accept from their configuration files.
validate_jvm_flag() {
  _matches "$1" '^-(Xm[xs][0-9]+[kmg]|Xss[0-9]+[kmg]|XX:[+-][A-Za-z0-9]+|XX:(MaxRAMPercentage|InitialRAMPercentage|MinRAMPercentage|ActiveProcessorCount|MaxRAM|MaxHeapSize|ThreadStackSize|ParallelGCThreads|ConcGCThreads|CICompilerCount)=[0-9.]+[kmg]?)$' ||
    usage_error "unsupported JVM flag '$1'"
}

# validate_int FLAG VALUE MIN MAX
validate_int() {
  _matches "$2" '^[0-9]{1,6}$' || usage_error "$1 must be a whole number, got '$2'"
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    usage_error "$1 must be between $3 and $4, got '$2'"
  fi
}

# split_list LIST: prints the comma-separated items of LIST, one per line. Exit 2 on empty
# items.
split_list() {
  local list="$1" item
  case "$list" in
    "" | ,* | *, | *,,*) usage_error "invalid list '$list' (expected a,b,c)" ;;
  esac
  while [ -n "$list" ]; do
    item="${list%%,*}"
    if [ "$item" = "$list" ]; then
      list=""
    else
      list="${list#*,}"
    fi
    printf '%s\n' "$item"
  done
}

# in_list ITEM LIST: succeeds when ITEM is one of the comma-separated items of LIST.
in_list() {
  case ",$2," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# ---- JDK helpers -------------------------------------------------------------------------------
# host_jdk_arch: the JDK catalog architecture of this machine (aarch64 or x64).
host_jdk_arch() {
  case "$(uname -m)" in
    aarch64 | arm64) printf 'aarch64' ;;
    x86_64 | amd64) printf 'x64' ;;
    *) die "unsupported machine architecture: $(uname -m)" ;;
  esac
}

# catalog_rows: prints the data rows of the JDK catalog (no comments, no header).
catalog_rows() {
  awk -F, '$1 != "" && $1 !~ /^#/ && $1 != "jdk_id"' "$JDK_CATALOG"
}

# sha256_of FILE: prints the SHA-256 of FILE in lower-case hex.
sha256_of() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$1")" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$1")" || return 1
  else
    die "required command not found: sha256sum or shasum"
  fi
  printf '%s' "${out%% *}"
}

# java_major JAVA: prints the feature release (8, 11, 17, 21) of the java launcher JAVA.
java_major() {
  local v
  v="$("$1" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
  case "$v" in
    1.*) v="${v#1.}" ;;
  esac
  printf '%s' "${v%%[._+-]*}"
}

# jvm_container_log_flags MAJOR: JVM flags that print the container detection log.
# JDK 8 has the diagnostic flag PrintContainerInfo; JDK 11 and later use unified logging.
jvm_container_log_flags() {
  if [ "$1" = 8 ]; then
    printf '%s\n' -XX:+UnlockDiagnosticVMOptions -XX:+PrintContainerInfo
  else
    printf '%s\n' -Xlog:os+container=trace
  fi
}

# jdk_dirs ROOT [LIST]: prints the JDK IDs under ROOT (directories with bin/java whose name
# is a valid JDK ID), sorted, optionally restricted to the comma-separated LIST.
jdk_dirs() {
  local root="$1" only="${2:-}" d id
  for d in "$root"/*; do
    [ -x "$d/bin/java" ] || continue
    id="$(basename "$d")"
    _matches "$id" '^(corretto|temurin)-[0-9][0-9a-z.+-]{2,30}$' || continue
    if [ -n "$only" ] && ! in_list "$id" "$only"; then continue; fi
    printf '%s\n' "$id"
  done | LC_ALL=C sort
}

# cgroup_fs_type [MOUNTINFO]: file system type of the /sys/fs/cgroup mount (cgroup2 on a
# cgroup v2 host, tmpfs on a cgroup v1 host), from /proc/self/mountinfo by default.
cgroup_fs_type() {
  local f="${1:-/proc/self/mountinfo}"
  [ -r "$f" ] || return 0
  awk '$5 == "/sys/fs/cgroup" { for (i = 7; i <= NF; i++) if ($i == "-") { t = $(i + 1); break } } END { print t }' "$f"
}

# cgroup_version [MOUNTINFO]: prints v2, v1 or unknown.
cgroup_version() {
  case "$(cgroup_fs_type "${1:-}")" in
    cgroup2) printf 'v2' ;;
    tmpfs | cgroup) printf 'v1' ;;
    *) printf 'unknown' ;;
  esac
}

# ---- AWS helpers -------------------------------------------------------------------------------
# setup_aws_env PROFILE REGION
setup_aws_env() {
  if [ -n "$1" ]; then
    export AWS_PROFILE="$1"
  fi
  export AWS_REGION="$2" AWS_DEFAULT_REGION="$2" AWS_PAGER=""
}

# aws_lookup ARGS...: runs "aws ARGS --output json" and stores stdout in AWS_OUT.
# Returns 0 when found, 1 when the service reports that the resource does not exist.
# Any other error stops the script.
aws_lookup() {
  local err rc=0
  err="$TMP_WORK/aws-stderr"
  AWS_OUT="$(aws "$@" --output json 2>"$err")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if grep -Eq 'NotFound|NoSuchEntity|NoSuchBucket|NoSuchTagSet|does not exist|404' "$err"; then
    AWS_OUT=""
    return 1
  fi
  cat "$err" >&2
  die "aws $1 $2 failed (exit code $rc)"
}

# Prints the account and identity that the AWS CLI uses, so the operator can check them.
show_identity() {
  local out
  out="$(aws sts get-caller-identity --output json)" ||
    die "cannot call sts get-caller-identity; check your AWS credentials and --profile"
  printf 'AWS account:  %s\n' "$(printf '%s' "$out" | jq -r '.Account')"
  printf 'AWS identity: %s\n' "$(printf '%s' "$out" | jq -r '.Arn')"
}

# confirm PHRASE: the operator must type PHRASE, unless --yes was given (ASSUME_YES=1).
confirm() {
  local answer=""
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  [ -t 0 ] || die "stdin is not a terminal; re-run with --yes to confirm. Nothing was changed."
  printf 'Type %s to continue: ' "$1" >&2
  read -r answer || answer=""
  [ "$answer" = "$1" ] || die "not confirmed. Nothing was changed."
}

# ---- tag helpers -------------------------------------------------------------------------------
# The tag values are validated (validate_owner, validate_run_id), so they need no quoting.
# tags_shorthand OWNER RUN_ID [NAME]: EC2/IAM CLI shorthand, Key=..,Value=.. items.
tags_shorthand() {
  printf '{Key=%s,Value=%s},{Key=%s,Value=%s},{Key=%s,Value=%s}' \
    "$SAMPLE_TAG_KEY" "$SAMPLE_TAG_VALUE" "$OWNER_TAG_KEY" "$1" "$RUN_ID_TAG_KEY" "$2"
  if [ -n "${3:-}" ]; then printf ',{Key=Name,Value=%s}' "$3"; fi
}

# has_run_tags RUN_ID: reads a tag list ([{"Key":..,"Value":..}]) or a tag map ({"k":"v"}) on
# stdin and succeeds when it carries the project tag and the run-id tag RUN_ID.
has_run_tags() {
  jq -e --arg k "$SAMPLE_TAG_KEY" --arg v "$SAMPLE_TAG_VALUE" --arg rk "$RUN_ID_TAG_KEY" --arg rv "$1" '
    (if type == "array" then map({key: (.Key // .key), value: (.Value // .value)}) | from_entries
     else (. // {}) end) | .[$k] == $v and .[$rk] == $rv' >/dev/null
}

# tag_value KEY: reads a tag list or map on stdin and prints the value of KEY (empty if absent).
tag_value() {
  jq -r --arg k "$1" '(if type == "array" then map({key: (.Key // .key), value: (.Value // .value)}) | from_entries else (. // {}) end) | .[$k] // empty'
}

# Resource names derived from the run ID.
bucket_name() { printf '%s-%s' "$NAME_PREFIX" "$1"; }
role_name() { printf '%s-%s-ec2' "$NAME_PREFIX" "$1"; }
sg_name() { printf '%s-%s' "$NAME_PREFIX" "$1"; }

# log_resource FILE TYPE ID OWNER RUN_ID: appends one JSON line (time, type, id, tags) to the
# resources log FILE. Does nothing when FILE is empty.
log_resource() {
  [ -n "$1" ] || return 0
  jq -cn --arg t "$2" --arg id "$3" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pk "$SAMPLE_TAG_KEY" --arg pv "$SAMPLE_TAG_VALUE" --arg ok "$OWNER_TAG_KEY" --arg ov "$4" \
    --arg rk "$RUN_ID_TAG_KEY" --arg rv "$5" \
    '{time: $time, type: $t, id: $id, tags: {($pk): $pv, ($ok): $ov, ($rk): $rv}}' >>"$1"
}

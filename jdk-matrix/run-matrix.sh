#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Records the JVM defaults of every JDK under --jdk-root on this host: java -version,
# -XX:+PrintFlagsFinal (repeated, to show that the defaults are stable), PrintFlagsFinal with
# diagnostic flags unlocked, -XshowSettings:system and -XshowSettings:vm. Optionally runs the
# unlocked PrintFlagsFinal inside a container without limits and counts LSE instructions in
# libjvm.so. flags-to-csv.sh reads the unlocked output, because JDK 16 and later declare most
# intrinsic flags (UseAESIntrinsics, UseSHA*Intrinsics, UseCRC32Intrinsics, ...) as diagnostic.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --jdk-root DIR --out DIR --host-label LABEL [options]

For each JDK directory DIR/<jdk-id> (as created by lib/fetch-jdk.sh), writes
OUT/LABEL/<jdk-id>/: version.txt, printflagsfinal-r<N>.txt, printflagsfinal-diag.txt,
showsettings-system.txt, showsettings-vm.txt, exit-codes.txt and repeats.txt (whether all
repeats are identical). Nothing outside OUT is changed.

Options:
  --jdk-root DIR      Directory that contains one subdirectory per JDK ID
  --out DIR           Result directory
  --host-label LABEL  Name of this host in the result tree, for example c9g
  --jdks LIST         Only these comma-separated JDK IDs (default: all under --jdk-root)
  --repeats N         PrintFlagsFinal repeats, 1 to 10 (default: 3)
  --in-docker IMAGE   Also run PrintFlagsFinal with diagnostic flags unlocked in a container
                      of IMAGE without limits (printflagsfinal-docker.txt); needs docker
  --libjvm-lse        Also run libjvm-lse.sh on each JDK (aarch64 only; needs objdump, nm)
  -h, --help          Show this help

Exit codes: 0 success, 1 runtime error, 2 usage error. A JVM that exits with an error is
recorded in exit-codes.txt and does not stop the run.
EOF
}

JDK_ROOT=""
OUT=""
HOST_LABEL=""
ONLY=""
REPEATS=3
IMAGE=""
LSE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jdk-root) need_arg "$@"; JDK_ROOT="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --host-label) need_arg "$@"; HOST_LABEL="$2"; shift 2 ;;
    --jdks) need_arg "$@"; ONLY="$2"; shift 2 ;;
    --repeats) need_arg "$@"; REPEATS="$2"; shift 2 ;;
    --in-docker) need_arg "$@"; IMAGE="$2"; shift 2 ;;
    --libjvm-lse) LSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$JDK_ROOT" ] || usage_error "--jdk-root is required"
[ -n "$OUT" ] || usage_error "--out is required"
[ -n "$HOST_LABEL" ] || usage_error "--host-label is required"
validate_host_label "$HOST_LABEL"
validate_int --repeats "$REPEATS" 1 10
if [ -n "$ONLY" ]; then
  items="$(split_list "$ONLY")" || exit 2
  for id in $items; do validate_jdk_id "$id"; done
fi
if [ -n "$IMAGE" ]; then
  validate_image "$IMAGE"
  require_cmd docker
fi
[ -d "$JDK_ROOT" ] || die "--jdk-root $JDK_ROOT is not a directory"
JDK_ROOT="$(cd "$JDK_ROOT" && pwd)"

IDS="$(jdk_dirs "$JDK_ROOT" "$ONLY")"
[ -n "$IDS" ] || die "no JDK directories found under $JDK_ROOT"

# run_jvm FILE EXITS LABEL CMD...: runs CMD with stdout and stderr in FILE and appends
# "LABEL=<exit code>" to EXITS.
run_jvm() {
  local file="$1" exits="$2" label="$3" rc=0
  shift 3
  "$@" >"$file" 2>&1 || rc=$?
  printf '%s=%s\n' "$label" "$rc" >>"$exits"
}

for id in $IDS; do
  java="$JDK_ROOT/$id/bin/java"
  dir="$OUT/$HOST_LABEL/$id"
  mkdir -p "$dir"
  exits="$dir/exit-codes.txt"
  : >"$exits"
  info "== $id"
  run_jvm "$dir/version.txt" "$exits" version "$java" -version
  r=1
  while [ "$r" -le "$REPEATS" ]; do
    run_jvm "$dir/printflagsfinal-r$r.txt" "$exits" "printflagsfinal-r$r" "$java" -XX:+PrintFlagsFinal -version
    r=$((r + 1))
  done
  run_jvm "$dir/printflagsfinal-diag.txt" "$exits" printflagsfinal-diag \
    "$java" -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlagsFinal -version
  run_jvm "$dir/showsettings-system.txt" "$exits" showsettings-system "$java" -XshowSettings:system -version
  run_jvm "$dir/showsettings-vm.txt" "$exits" showsettings-vm "$java" -XshowSettings:vm -version

  same=yes
  r=2
  while [ "$r" -le "$REPEATS" ]; do
    cmp -s "$dir/printflagsfinal-r1.txt" "$dir/printflagsfinal-r$r.txt" || same=no
    r=$((r + 1))
  done
  printf 'repeats=%s identical=%s\n' "$REPEATS" "$same" >"$dir/repeats.txt"
  if [ "$same" = no ]; then warn "$id: PrintFlagsFinal output differs between repeats"; fi

  if [ -n "$IMAGE" ]; then
    run_jvm "$dir/printflagsfinal-docker.txt" "$exits" printflagsfinal-docker \
      docker run --rm --network none --read-only --tmpfs /tmp --user "$LAB_UID:$LAB_UID" \
      --cap-drop ALL --security-opt no-new-privileges \
      -v "$JDK_ROOT/$id:/jdk:ro" "$IMAGE" /jdk/bin/java -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlagsFinal -version
  fi
  if [ "$LSE" = 1 ]; then
    run_jvm "$dir/libjvm-lse.txt" "$exits" libjvm-lse bash "$SCRIPT_DIR/libjvm-lse.sh" "$JDK_ROOT/$id"
  fi
done
echo "Results: $OUT/$HOST_LABEL"

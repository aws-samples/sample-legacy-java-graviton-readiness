#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Runs the correctness workloads of jdk-matrix/java on every JDK under --jdk-root: the
# SanityWorkload soak (default) or, with --reproducer, UnsafeShiftCheck with the JIT and with
# -Xint as a control. Each JDK compiles the sources with its own javac. JVM crash logs
# (hs_err_pid*.log) are written into the result directory.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --jdk-root DIR --out DIR --host-label LABEL [options]

Soak mode (default): OUT/LABEL/<jdk-id>/soak.log (JSON lines), summary.json and hs_err/.
Reproducer mode: OUT/LABEL/<jdk-id>/{jit,xint}-r<N>.json and hs_err/.

Options:
  --jdk-root DIR      Directory that contains one subdirectory per JDK ID
  --out DIR           Result directory
  --host-label LABEL  Name of this host in the result tree
  --jdks LIST         Only these comma-separated JDK IDs (default: all)
  --minutes N         Soak duration per JDK, 1 to 1440 (default: 30)
  --reproducer        Run UnsafeShiftCheck instead of the soak
  --repeats N         Reproducer runs per mode, 1 to 20 (default: 5)
  --seconds N         Duration of one reproducer run, 1 to 3600 (default: 60)
  -h, --help          Show this help

Exit codes: 0 when every run passed, 1 when a run failed or crashed (the remaining runs
still run), 2 usage error.
EOF
}

JDK_ROOT=""
OUT=""
HOST_LABEL=""
ONLY=""
MINUTES=30
REPRO=0
REPEATS=5
SECONDS_PER_RUN=60

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jdk-root) need_arg "$@"; JDK_ROOT="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --host-label) need_arg "$@"; HOST_LABEL="$2"; shift 2 ;;
    --jdks) need_arg "$@"; ONLY="$2"; shift 2 ;;
    --minutes) need_arg "$@"; MINUTES="$2"; shift 2 ;;
    --reproducer) REPRO=1; shift ;;
    --repeats) need_arg "$@"; REPEATS="$2"; shift 2 ;;
    --seconds) need_arg "$@"; SECONDS_PER_RUN="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$JDK_ROOT" ] || usage_error "--jdk-root is required"
[ -n "$OUT" ] || usage_error "--out is required"
[ -n "$HOST_LABEL" ] || usage_error "--host-label is required"
validate_host_label "$HOST_LABEL"
validate_int --minutes "$MINUTES" 1 1440
validate_int --repeats "$REPEATS" 1 20
validate_int --seconds "$SECONDS_PER_RUN" 1 3600
if [ -n "$ONLY" ]; then
  items="$(split_list "$ONLY")" || exit 2
  for id in $items; do validate_jdk_id "$id"; done
fi
[ -d "$JDK_ROOT" ] || die "--jdk-root $JDK_ROOT is not a directory"
JDK_ROOT="$(cd "$JDK_ROOT" && pwd)"
IDS="$(jdk_dirs "$JDK_ROOT" "$ONLY")"
[ -n "$IDS" ] || die "no JDK directories found under $JDK_ROOT"
init_tmpdir

FAILED=0
# run_one ID DIR NAME JAVA_ARGS...: runs java, stdout in DIR/NAME, hs_err files in DIR/hs_err.
run_one() {
  local id="$1" dir="$2" name="$3" rc=0 start end
  shift 3
  mkdir -p "$dir/hs_err"
  start="$(date +%s)"
  "$JDK_ROOT/$id/bin/java" "-XX:ErrorFile=$dir/hs_err/hs_err_pid%p.log" "$@" \
    >"$dir/$name" 2>"$dir/${name%.*}.stderr" || rc=$?
  end="$(date +%s)"
  printf '{"jdk_id":"%s","run":"%s","exit_code":%s,"seconds":%s}\n' \
    "$id" "$name" "$rc" "$((end - start))" >>"$dir/runs.jsonl"
  if [ "$rc" -ne 0 ]; then
    warn "$id $name exited with $rc"
    FAILED=1
  fi
  return 0
}

for id in $IDS; do
  dir="$OUT/$HOST_LABEL/$id"
  mkdir -p "$dir"
  classes="$TMP_WORK/classes-$id"
  mkdir -p "$classes"
  "$JDK_ROOT/$id/bin/javac" -nowarn -d "$classes" "$SCRIPT_DIR"/java/*.java \
    >"$dir/javac.txt" 2>&1 || die "$id: javac failed, see $dir/javac.txt"
  info "== $id"
  if [ "$REPRO" = 1 ]; then
    r=1
    while [ "$r" -le "$REPEATS" ]; do
      run_one "$id" "$dir" "jit-r$r.json" -cp "$classes" UnsafeShiftCheck --seconds "$SECONDS_PER_RUN"
      run_one "$id" "$dir" "xint-r$r.json" -Xint -cp "$classes" UnsafeShiftCheck --seconds "$SECONDS_PER_RUN"
      r=$((r + 1))
    done
  else
    run_one "$id" "$dir" soak.log -cp "$classes" SanityWorkload --seconds "$((MINUTES * 60))"
    tail -n 1 "$dir/soak.log" >"$dir/summary.json" || true
  fi
  # Keep the hs_err directory only when a JVM crashed.
  rmdir "$dir/hs_err" 2>/dev/null || warn "$id: JVM crash log(s) in $dir/hs_err"
done
echo "Results: $OUT/$HOST_LABEL"
exit "$FAILED"

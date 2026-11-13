#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Measures the memory footprint of JVM threads in a container: ThreadFootprint starts N
# threads, and the run records RSS, anonymous huge pages and the cgroup memory figures
# together with the NMT summary, for each JDK, transparent huge page (THP) mode, thread
# count and -Xss value. Changes the host's THP mode for the runs and restores it on exit.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=docker-common.sh
. "$SCRIPT_DIR/docker-common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --jdk-root DIR --out DIR --host-label LABEL [options]

Matrix mode writes OUT/LABEL/<thp>/<jdk-id>/<threads>-<xss>/r<N>/: footprint.json (one JSON
line per sample), nmt.txt (NMT summary at exit), docker-inspect.json and meta.json, plus
OUT/LABEL/<thp>/thp.txt. --oom-demo instead runs 1000 threads with THP "always" under a
1 GiB limit and writes OUT/LABEL/oom-demo/<jdk-id>/r<N>/.

Options:
  --jdk-root DIR      Directory that contains one subdirectory per JDK ID
  --out DIR           Result directory
  --host-label LABEL  Name of this host in the result tree, for example c9g
  --image REF         Base image (default: the pinned Amazon Linux 2023 image)
  --probe-src DIR     Probe sources (default: cgroup-lab/java)
  --jdks LIST         Only these comma-separated JDK IDs (default: all)
  --thp-modes LIST    THP modes to test: never, madvise, always (default: never,madvise,always)
  --threads LIST      Thread counts (default: 0,200,1000)
  --xss LIST          default or sizes such as 1m, 512k (default: default,1m)
  --samples LIST      Sample times in seconds after all threads started (default: 5,30)
  --memory SIZE       Container memory limit for the matrix, such as 4g (default: 4g)
  --repeats N         Repeats per cell, 1 to 20 (default: 3)
  --oom-demo          Run the OOM demonstration instead of the matrix
  --timeout SECONDS   Limit for one container run, 10 to 7200 (default: 900)
  --dry-run           Print the docker commands; run nothing and change nothing
  -h, --help          Show this help

Changing the THP mode needs root (it writes /sys/kernel/mm/transparent_hugepage/enabled).
Exit codes: 0 success, 1 runtime error, 2 usage error.
EOF
}

JDK_ROOT=""
OUT=""
HOST_LABEL=""
IMAGE="$DEFAULT_IMAGE"
PROBE_SRC="$SCRIPT_DIR/../java"
ONLY=""
THP_MODES="never,madvise,always"
THREADS="0,200,1000"
XSS="default,1m"
SAMPLES="5,30"
MEMORY="4g"
REPEATS=3
OOM_DEMO=0
THP_FILE="${THREAD_LAB_THP_FILE:-/sys/kernel/mm/transparent_hugepage/enabled}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jdk-root) need_arg "$@"; JDK_ROOT="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --host-label) need_arg "$@"; HOST_LABEL="$2"; shift 2 ;;
    --image) need_arg "$@"; IMAGE="$2"; shift 2 ;;
    --probe-src) need_arg "$@"; PROBE_SRC="$2"; shift 2 ;;
    --jdks) need_arg "$@"; ONLY="$2"; shift 2 ;;
    --thp-modes) need_arg "$@"; THP_MODES="$2"; shift 2 ;;
    --threads) need_arg "$@"; THREADS="$2"; shift 2 ;;
    --xss) need_arg "$@"; XSS="$2"; shift 2 ;;
    --samples) need_arg "$@"; SAMPLES="$2"; shift 2 ;;
    --memory) need_arg "$@"; MEMORY="$2"; shift 2 ;;
    --repeats) need_arg "$@"; REPEATS="$2"; shift 2 ;;
    --oom-demo) OOM_DEMO=1; shift ;;
    --timeout) need_arg "$@"; RUN_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$JDK_ROOT" ] || usage_error "--jdk-root is required"
[ -n "$OUT" ] || usage_error "--out is required"
[ -n "$HOST_LABEL" ] || usage_error "--host-label is required"
validate_host_label "$HOST_LABEL"
validate_image "$IMAGE"
validate_int --repeats "$REPEATS" 1 20
validate_int --timeout "$RUN_TIMEOUT" 10 7200
_matches "$MEMORY" '^[0-9]{1,4}[mg]$' || usage_error "invalid --memory '$MEMORY' (for example 4g)"
if [ -n "$ONLY" ]; then
  items="$(split_list "$ONLY")" || exit 2
  for id in $items; do validate_jdk_id "$id"; done
fi
MODE_LIST="$(split_list "$THP_MODES")" || exit 2
for m in $MODE_LIST; do
  case "$m" in never | madvise | always) ;; *) usage_error "invalid THP mode '$m'" ;; esac
done
THREAD_LIST="$(split_list "$THREADS")" || exit 2
for t in $THREAD_LIST; do validate_int --threads "$t" 0 20000; done
XSS_LIST="$(split_list "$XSS")" || exit 2
for x in $XSS_LIST; do
  _matches "$x" '^(default|[0-9]{1,5}[km])$' || usage_error "invalid --xss value '$x'"
done
SAMPLE_LIST="$(split_list "$SAMPLES")" || exit 2
for s in $SAMPLE_LIST; do validate_int --samples "$s" 0 3600; done
[ -d "$PROBE_SRC" ] || die "--probe-src $PROBE_SRC is not a directory"
[ -d "$JDK_ROOT" ] || die "--jdk-root $JDK_ROOT is not a directory"
JDK_ROOT="$(cd "$JDK_ROOT" && pwd)"
PROBE_SRC="$(cd "$PROBE_SRC" && pwd)"
IDS="$(jdk_dirs "$JDK_ROOT" "$ONLY")"
[ -n "$IDS" ] || die "no JDK directories found under $JDK_ROOT"

if [ "$OOM_DEMO" = 1 ]; then
  MODE_LIST="always"
  THREAD_LIST="1000"
  XSS_LIST="default"
  MEMORY="1g"
  OOM_REPEATS=5
fi

# current_thp: the selected mode. The kernel marks it with brackets ("always [madvise] never");
# a plain word (a test fixture) is taken as is.
current_thp() {
  local t
  t="$(cat "$THP_FILE")"
  case "$t" in
    *"["*) printf '%s' "$t" | sed -n 's/.*\[\([a-z]*\)\].*/\1/p' ;;
    *) printf '%s' "$t" ;;
  esac
}
ORIGINAL_THP=""
restore_thp() {
  if [ -n "$ORIGINAL_THP" ] && [ "$(current_thp)" != "$ORIGINAL_THP" ]; then
    printf '%s' "$ORIGINAL_THP" >"$THP_FILE" && info "THP mode restored to $ORIGINAL_THP"
  fi
}
set_thp() {
  if [ "$DRY_RUN" = 1 ]; then
    show_cmd "echo $1 > $THP_FILE"
    return 0
  fi
  printf '%s' "$1" >"$THP_FILE" || die "cannot write $THP_FILE (run as root)"
  [ "$(current_thp)" = "$1" ] || die "THP mode did not change to $1"
}

if [ "$DRY_RUN" = 0 ]; then
  require_linux_docker
  require_cmd jq
  [ -r "$THP_FILE" ] || die "$THP_FILE not found: this kernel has no transparent huge pages"
  ORIGINAL_THP="$(current_thp)"
  EXIT_HOOK=restore_thp
fi
init_tmpdir

# run_cell JDK_ID DIR THREADS XSS MEMORY: one ThreadFootprint container run.
run_cell() {
  local id="$1" dir="$2" threads="$3" xss="$4" mem="$5" xflags=() samples
  if [ "$xss" != default ]; then xflags=("-Xss$xss"); fi
  samples="$(printf '%s' "$SAMPLE_LIST" | tr '\n' ',')"
  samples="${samples%,}"
  [ "$DRY_RUN" = 1 ] || mkdir -p "$dir"
  next_name
  local start end
  start="$(epoch_ms)"
  docker_run "$CONTAINER_NAME" "$dir/stdout.txt" "$dir/stderr.txt" "${base[@]}" "--memory=$mem" \
    "$IMAGE" /jdk/bin/java -XX:NativeMemoryTracking=summary -XX:+UnlockDiagnosticVMOptions \
    -XX:+PrintNMTStatistics ${xflags[@]+"${xflags[@]}"} -cp /probe ThreadFootprint \
    --threads "$threads" --samples "$samples"
  end="$(epoch_ms)"
  [ "$DRY_RUN" = 0 ] || return 0
  grep '^{' "$dir/stdout.txt" >"$dir/footprint.json" || true
  grep -v '^{' "$dir/stdout.txt" >"$dir/nmt.txt" || true
  rm -f -- "$dir/stdout.txt"
  jq -n --arg host "$HOST_LABEL" --arg id "$id" --argjson threads "$threads" --arg xss "$xss" \
    --arg mem "$mem" --arg thp "$(current_thp)" --arg image "$IMAGE" --argjson start "$start" \
    --argjson end "$end" --argjson rc "$LAST_RC" --slurpfile inspect "$dir/docker-inspect.json" \
    '{host: $host, jdk_id: $id, threads: $threads, xss: $xss, memory: $mem, thp: $thp,
      image: $image, start_ms: $start, end_ms: $end, exit_code: $rc,
      oom_killed: $inspect[0][0].State.OOMKilled}' >"$dir/meta.json"
}

for mode in $MODE_LIST; do
  set_thp "$mode"
  if [ "$DRY_RUN" = 0 ] && [ "$OOM_DEMO" = 0 ]; then
    mkdir -p "$OUT/$HOST_LABEL/$mode"
    {
      printf 'enabled: %s\n' "$(cat "$THP_FILE")"
      printf 'defrag: %s\n' "$(cat "$(dirname "$THP_FILE")/defrag" 2>/dev/null || printf 'unknown')"
    } >"$OUT/$HOST_LABEL/$mode/thp.txt"
  fi
  for id in $IDS; do
    jdk="$JDK_ROOT/$id"
    classes="$TMP_WORK/probe-$id"
    if [ "$DRY_RUN" = 0 ] && [ ! -d "$classes" ]; then compile_probes "$jdk" "$PROBE_SRC" "$classes"; fi
    base=()
    while IFS= read -r a; do base+=("$a"); done < <(container_args "$jdk" "$classes")
    for threads in $THREAD_LIST; do
      for xss in $XSS_LIST; do
        if [ "$OOM_DEMO" = 1 ]; then
          r=1
          while [ "$r" -le "$OOM_REPEATS" ]; do
            info "== oom-demo $id r$r"
            run_cell "$id" "$OUT/$HOST_LABEL/oom-demo/$id/r$r" "$threads" "$xss" "$MEMORY"
            r=$((r + 1))
          done
          continue
        fi
        r=1
        while [ "$r" -le "$REPEATS" ]; do
          info "== $mode $id $threads-$xss r$r"
          run_cell "$id" "$OUT/$HOST_LABEL/$mode/$id/$threads-$xss/r$r" "$threads" "$xss" "$MEMORY"
          r=$((r + 1))
        done
      done
    done
  done
done
restore_thp
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing was run or changed."
else
  echo "Results: $OUT/$HOST_LABEL"
fi

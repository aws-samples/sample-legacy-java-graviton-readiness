#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Runs the container-detection probe and the allocation-pressure program of cgroup-lab/java
# in docker containers with the memory and CPU limits of cgroup-lab/configs-docker.csv, for
# every JDK under --jdk-root. The JDK and the compiled probes are bind-mounted read-only
# into one pinned base image, so every JDK runs in the same user space.
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

For every JDK, configuration and repeat, writes
OUT/LABEL/<cgroup>/<jdk-id>/<config>/r<N>/: meta.json, jvm-container.log (the JVM's
container detection log), showsettings-system.txt, docker-inspect.json, and probe.json
(probe configurations) or alloc.log and kernel-oom.log (allocation configurations).

Options:
  --jdk-root DIR        Directory that contains one subdirectory per JDK ID
  --out DIR             Result directory
  --host-label LABEL    Name of this host in the result tree, for example c9g
  --image REF           Base image (default: the pinned Amazon Linux 2023 image)
  --probe-src DIR       Probe sources (default: cgroup-lab/java)
  --configs-file FILE   Configuration table (default: cgroup-lab/configs-docker.csv)
  --configs LIST        Only these comma-separated configurations (default: all)
  --jdks LIST           Only these comma-separated JDK IDs (default: all)
  --repeats N           Repeats of each probe configuration, 1 to 20 (default: 3)
  --alloc-repeats N     Repeats of each allocation configuration, 1 to 20 (default: 5)
  --cgroup-label LABEL  v1, v2 or auto (default: auto, from /proc/self/mountinfo)
  --timeout SECONDS     Limit for one container run, 10 to 7200 (default: 900)
  --dry-run             Print the docker commands; run nothing (works on any OS)
  -h, --help            Show this help

Needs a Linux host with docker, journalctl (for the kernel OOM log) and timeout.
Exit codes: 0 success, 1 runtime error, 2 usage error. A JVM or container that fails is
recorded in meta.json and does not stop the run.
EOF
}

JDK_ROOT=""
OUT=""
HOST_LABEL=""
IMAGE="$DEFAULT_IMAGE"
PROBE_SRC="$SCRIPT_DIR/../java"
CONFIGS_FILE="$SCRIPT_DIR/../configs-docker.csv"
ONLY_CONFIGS=""
ONLY=""
REPEATS=3
ALLOC_REPEATS=5
CG_LABEL="auto"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jdk-root) need_arg "$@"; JDK_ROOT="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --host-label) need_arg "$@"; HOST_LABEL="$2"; shift 2 ;;
    --image) need_arg "$@"; IMAGE="$2"; shift 2 ;;
    --probe-src) need_arg "$@"; PROBE_SRC="$2"; shift 2 ;;
    --configs-file) need_arg "$@"; CONFIGS_FILE="$2"; shift 2 ;;
    --configs) need_arg "$@"; ONLY_CONFIGS="$2"; shift 2 ;;
    --jdks) need_arg "$@"; ONLY="$2"; shift 2 ;;
    --repeats) need_arg "$@"; REPEATS="$2"; shift 2 ;;
    --alloc-repeats) need_arg "$@"; ALLOC_REPEATS="$2"; shift 2 ;;
    --cgroup-label) need_arg "$@"; CG_LABEL="$2"; shift 2 ;;
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
validate_int --alloc-repeats "$ALLOC_REPEATS" 1 20
validate_int --timeout "$RUN_TIMEOUT" 10 7200
case "$CG_LABEL" in
  auto | v1 | v2) ;;
  *) usage_error "invalid --cgroup-label '$CG_LABEL' (v1, v2 or auto)" ;;
esac
if [ -n "$ONLY" ]; then
  items="$(split_list "$ONLY")" || exit 2
  for id in $items; do validate_jdk_id "$id"; done
fi
if [ -n "$ONLY_CONFIGS" ]; then
  items="$(split_list "$ONLY_CONFIGS")" || exit 2
  for c in $items; do _matches "$c" '^[A-Z][0-9]{1,2}$' || usage_error "invalid configuration '$c'"; done
fi
[ -r "$CONFIGS_FILE" ] || die "configuration file not found: $CONFIGS_FILE"
[ -d "$PROBE_SRC" ] || die "--probe-src $PROBE_SRC is not a directory"
[ -d "$JDK_ROOT" ] || die "--jdk-root $JDK_ROOT is not a directory"
JDK_ROOT="$(cd "$JDK_ROOT" && pwd)"
PROBE_SRC="$(cd "$PROBE_SRC" && pwd)"

# Read and validate the configuration table: parallel arrays, one entry per configuration.
C_NAME=()
C_PROG=()
C_DOCKER=()
C_JVM=()
while IFS=, read -r name prog dflags jflags _; do
  case "$name" in "" | \#* | config) continue ;; esac
  if [ -n "$ONLY_CONFIGS" ] && ! in_list "$name" "$ONLY_CONFIGS"; then continue; fi
  case "$prog" in probe | alloc) ;; *) die "configuration $name: unknown program '$prog'" ;; esac
  for f in $dflags; do validate_docker_flag "$f"; done
  for f in $jflags; do validate_jvm_flag "$f"; done
  C_NAME+=("$name")
  C_PROG+=("$prog")
  C_DOCKER+=("$dflags")
  C_JVM+=("$jflags")
done <"$CONFIGS_FILE"
[ "${#C_NAME[@]}" -gt 0 ] || die "no configurations selected"

IDS="$(jdk_dirs "$JDK_ROOT" "$ONLY")"
[ -n "$IDS" ] || die "no JDK directories found under $JDK_ROOT"

if [ "$DRY_RUN" = 0 ]; then
  require_linux_docker
  require_cmd journalctl jq
fi
if [ "$CG_LABEL" = auto ]; then
  CG_LABEL="$(cgroup_version)"
  if [ "$CG_LABEL" = unknown ]; then
    [ "$DRY_RUN" = 1 ] || die "cannot detect the cgroup version; pass --cgroup-label"
    CG_LABEL=v2
  fi
fi
init_tmpdir

for id in $IDS; do
  jdk="$JDK_ROOT/$id"
  classes="$TMP_WORK/probe-$id"
  if [ "$DRY_RUN" = 1 ]; then
    major=8
  else
    compile_probes "$jdk" "$PROBE_SRC" "$classes"
    major="$(java_major "$jdk/bin/java")"
  fi
  logflags=()
  while IFS= read -r a; do logflags+=("$a"); done < <(jvm_container_log_flags "$major")
  base=()
  while IFS= read -r a; do base+=("$a"); done < <(container_args "$jdk" "$classes")
  i=0
  while [ "$i" -lt "${#C_NAME[@]}" ]; do
    cfg="${C_NAME[$i]}"
    prog="${C_PROG[$i]}"
    # shellcheck disable=SC2206  # validated space-separated flags
    dflags=(${C_DOCKER[$i]})
    # shellcheck disable=SC2206  # validated space-separated flags
    jflags=(${C_JVM[$i]})
    n="$REPEATS"
    if [ "$prog" = alloc ]; then n="$ALLOC_REPEATS"; fi
    r=1
    while [ "$r" -le "$n" ]; do
      dir="$OUT/$HOST_LABEL/$CG_LABEL/$id/$cfg/r$r"
      [ "$DRY_RUN" = 1 ] || mkdir -p "$dir"
      info "== $id $cfg r$r"
      common=("${base[@]}" ${dflags[@]+"${dflags[@]}"} "$IMAGE" /jdk/bin/java ${jflags[@]+"${jflags[@]}"})
      docker_quick "$dir/jvm-container.log" "${common[@]}" "${logflags[@]}" -version
      docker_quick "$dir/showsettings-system.txt" "${common[@]}" -XshowSettings:system -version
      next_name
      start="$(epoch_ms)"
      start_s="$(date +%s)"
      if [ "$prog" = probe ]; then
        docker_run "$CONTAINER_NAME" "$dir/probe.json" "$dir/probe.stderr" "${common[@]}" -cp /probe ContainerProbe
      else
        docker_run "$CONTAINER_NAME" "$dir/alloc.log" "$dir/alloc.stderr" "${common[@]}" -cp /probe AllocPressure
      fi
      end="$(epoch_ms)"
      if [ "$DRY_RUN" = 0 ]; then
        if [ "$prog" = alloc ]; then
          journalctl -k --no-pager --since "@$start_s" 2>/dev/null |
            grep -E 'oom-kill|Killed process|Memory cgroup out of memory' >"$dir/kernel-oom.log" || true
        fi
        jq -n --arg host "$HOST_LABEL" --arg cg "$CG_LABEL" --arg id "$id" --arg cfg "$cfg" \
          --argjson r "$r" --arg prog "$prog" --arg d "${C_DOCKER[$i]}" --arg j "${C_JVM[$i]}" \
          --arg image "$IMAGE" --argjson start "$start" --argjson end "$end" --argjson rc "$LAST_RC" \
          --slurpfile inspect "$dir/docker-inspect.json" \
          '{host: $host, cgroup: $cg, jdk_id: $id, config: $cfg, repeat: $r, program: $prog,
            docker_flags: $d, jvm_flags: $j, image: $image, start_ms: $start, end_ms: $end,
            exit_code: $rc, oom_killed: $inspect[0][0].State.OOMKilled}' >"$dir/meta.json"
      fi
      r=$((r + 1))
    done
    i=$((i + 1))
  done
done
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing was run."
else
  echo "Results: $OUT/$HOST_LABEL/$CG_LABEL"
fi

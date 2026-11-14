#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Runs the cgroup lab on the EKS test cluster: one Kubernetes Job per JDK, configuration and
# repeat, on the Amazon Linux 2023 and the Bottlerocket node of one instance type (in parallel;
# one Job at a time per node). The init container downloads the JDK, checks its SHA-256 and compiles the
# probes; the main container runs them with the resources of configs-eks.csv. Collects the
# pod logs and status, then deletes the Job.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh"

NAMESPACE="jvm-cgroup-lab"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --instance-type TYPE --jdks LIST --out DIR [options]
       $SCRIPT_NAME --instance-type TYPE --print-job OS,JDK_ID,CONFIG

Writes OUT/<os>/<jdk-id>/<config>/r<N>/: pod.json, logs.txt, init.log, jvm-container.log,
showsettings-system.txt and probe.json or alloc.log; and OUT/nodes.json and
OUT/nodeinfo-pods.yaml and OUT/nodeinfo-<os>.txt. Uses the current kubectl context.

Options:
  --instance-type TYPE   Run on the nodes of this arm64 instance type, for example m8g.xlarge
                         or m9g.xlarge (node label node.kubernetes.io/instance-type); required.
                         Use a separate --out directory per type.
  --jdks LIST            Comma-separated JDK IDs of the catalog (aarch64 builds are used)
  --out DIR              Result directory
  --configs LIST         Only these configurations (default: all in configs-eks.csv)
  --nodegroups LIST      al2023, bottlerocket or both (default: al2023,bottlerocket)
  --repeats-probe N      Repeats of each probe configuration, 1 to 20 (default: 3)
  --repeats-alloc N      Repeats of each allocation configuration, 1 to 20 (default: 5)
  --image REF            Container image (default: the pinned Amazon Linux 2023 image)
  --timeout SECONDS      Wait limit for one Job, 60 to 7200 (default: 900)
  --skip-nodeinfo        Do not run the node information pods first
  --print-job OS,JDK_ID,CONFIG
                         Print the Job manifest for one run and exit (no cluster access)
  -h, --help             Show this help

Exit codes: 0 success, 1 runtime error or a failed collection, 2 usage error. A JVM that
fails or a container that is OOM-killed is a result, not a failure.
EOF
}

INSTANCE_TYPE=""
JDKS=""
OUT=""
ONLY_CONFIGS=""
NODEGROUPS="al2023,bottlerocket"
REPEATS_PROBE=3
REPEATS_ALLOC=5
IMAGE="$DEFAULT_IMAGE"
TIMEOUT=900
NODEINFO=1
PRINT_JOB=""
CONFIGS_FILE="$SCRIPT_DIR/../configs-eks.csv"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance-type) need_arg "$@"; INSTANCE_TYPE="$2"; shift 2 ;;
    --jdks) need_arg "$@"; JDKS="$2"; shift 2 ;;
    --out) need_arg "$@"; OUT="$2"; shift 2 ;;
    --configs) need_arg "$@"; ONLY_CONFIGS="$2"; shift 2 ;;
    --nodegroups) need_arg "$@"; NODEGROUPS="$2"; shift 2 ;;
    --repeats-probe) need_arg "$@"; REPEATS_PROBE="$2"; shift 2 ;;
    --repeats-alloc) need_arg "$@"; REPEATS_ALLOC="$2"; shift 2 ;;
    --image) need_arg "$@"; IMAGE="$2"; shift 2 ;;
    --timeout) need_arg "$@"; TIMEOUT="$2"; shift 2 ;;
    --skip-nodeinfo) NODEINFO=0; shift ;;
    --print-job) need_arg "$@"; PRINT_JOB="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$INSTANCE_TYPE" ] || usage_error "--instance-type is required, for example m8g.xlarge"
validate_instance_type "$INSTANCE_TYPE"
case "$INSTANCE_TYPE" in
  *g.* | *gd.* | *gn.*) ;;
  *) usage_error "--instance-type $INSTANCE_TYPE is not an arm64 (Graviton) type" ;;
esac
# Instance family (m8g, m9g) in the names of Jobs and node information pods, so that runs on
# different instance types can share the namespace.
FAMILY="${INSTANCE_TYPE%%.*}"
validate_image "$IMAGE"
validate_int --repeats-probe "$REPEATS_PROBE" 1 20
validate_int --repeats-alloc "$REPEATS_ALLOC" 1 20
validate_int --timeout "$TIMEOUT" 60 7200
OS_LIST="$(split_list "$NODEGROUPS")" || exit 2
for os in $OS_LIST; do
  case "$os" in al2023 | bottlerocket) ;; *) usage_error "invalid node group '$os'" ;; esac
done
if [ -n "$ONLY_CONFIGS" ]; then
  items="$(split_list "$ONLY_CONFIGS")" || exit 2
  for c in $items; do _matches "$c" '^K[0-9]{1,2}$' || usage_error "invalid configuration '$c'"; done
fi

# config_row NAME: the configs-eks.csv row of configuration NAME (validated), or nothing.
config_row() {
  awk -F, -v c="$1" '$1 == c { print; exit }' "$CONFIGS_FILE"
}
# catalog_aarch64 JDK_ID: "url,sha256,feature" of the aarch64 build.
catalog_aarch64() {
  # awk reads all of its input, so catalog_rows cannot fail with SIGPIPE under pipefail.
  catalog_rows | awk -F, -v id="$1" '!done && $1 == id && $5 == "aarch64" { print $6 "," $7 "," $3; done = 1 }'
}
check_quantity() { # CPU like 1, 2, 500m; memory like 1Gi, 512Mi
  _matches "$1" '^[0-9]{1,5}(m|Mi|Gi)?$' || die "invalid resource quantity '$1' in $CONFIGS_FILE"
}

# render_job NAME OS JDK_ID CONFIG REPEAT: prints the Job manifest.
render_job() {
  local name="$1" os="$2" id="$3" cfg="$4" rep="$5" row prog cpu_req cpu_lim mem_req mem_lim jflags
  local entry url sha feature cpu_limit_line=""
  row="$(config_row "$cfg")"
  [ -n "$row" ] || die "configuration $cfg not found in $CONFIGS_FILE"
  IFS=, read -r _ prog cpu_req cpu_lim mem_req mem_lim jflags _ <<EOF
$row
EOF
  case "$prog" in probe | alloc) ;; *) die "configuration $cfg: unknown program '$prog'" ;; esac
  check_quantity "$cpu_req"
  check_quantity "$mem_req"
  check_quantity "$mem_lim"
  if [ -n "$cpu_lim" ]; then
    check_quantity "$cpu_lim"
    cpu_limit_line="              cpu: \"$cpu_lim\""
  fi
  for f in $jflags; do validate_jvm_flag "$f"; done
  entry="$(catalog_aarch64 "$id")"
  [ -n "$entry" ] || die "no aarch64 catalog entry for $id"
  url="${entry%%,*}"
  sha="${entry#*,}"
  feature="${sha#*,}"
  sha="${sha%%,*}"
  case "$url" in https://*) ;; *) die "catalog URL for $id must use https" ;; esac
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: jvm-cgroup-lab
    lab/os: $os
    lab/jdk: $id
    lab/config: $cfg
    lab/repeat: "$rep"
  annotations:
    checkov.io/skip1: CKV_K8S_8=Run-to-completion Job; a liveness probe does not apply
    checkov.io/skip2: CKV_K8S_9=Run-to-completion Job; a readiness probe does not apply
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $TIMEOUT
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jvm-cgroup-lab
        lab/os: $os
        lab/jdk: $id
        lab/config: $cfg
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector:
        lab/os: $os
        node.kubernetes.io/instance-type: $INSTANCE_TYPE
      securityContext:
        runAsNonRoot: true
        runAsUser: $LAB_UID
        runAsGroup: $LAB_UID
        fsGroup: $LAB_UID
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fetch-jdk
          image: $IMAGE
          imagePullPolicy: Always
          command: ["/bin/bash", "/src/pod-fetch-jdk.sh"]
          env:
            - name: JDK_URL
              value: "$url"
            - name: JDK_SHA256
              value: "$sha"
            - name: HOME
              value: /work
          resources:
            requests:
              cpu: "1"
              memory: 1Gi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: work
              mountPath: /work
            - name: src
              mountPath: /src
              readOnly: true
            - name: scratch
              mountPath: /tmp
      containers:
        - name: probe
          image: $IMAGE
          imagePullPolicy: Always
          command: ["/bin/bash", "/src/pod-run.sh"]
          env:
            - name: PROGRAM
              value: $prog
            - name: JDK_MAJOR
              value: "$feature"
            - name: JVM_FLAGS
              value: "$jflags"
          resources:
            requests:
              cpu: "$cpu_req"
              memory: $mem_req
            limits:
              memory: $mem_lim
$cpu_limit_line
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: work
              mountPath: /work
              readOnly: true
            - name: src
              mountPath: /src
              readOnly: true
            - name: scratch
              mountPath: /tmp
      volumes:
        - name: work
          emptyDir:
            sizeLimit: 2Gi
        - name: scratch
          emptyDir:
            sizeLimit: 256Mi
        - name: src
          configMap:
            name: jvmlab-src
EOF
}

if [ -n "$PRINT_JOB" ]; then
  IFS=, read -r p_os p_id p_cfg <<EOF
$PRINT_JOB
EOF
  case "${p_os:-}" in al2023 | bottlerocket) ;; *) usage_error "--print-job: invalid node group '${p_os:-}'" ;; esac
  validate_jdk_id "${p_id:-}"
  _matches "${p_cfg:-}" '^K[0-9]{1,2}$' || usage_error "--print-job: invalid configuration '${p_cfg:-}'"
  render_job "jvmlab-$p_os-$FAMILY-example" "$p_os" "$p_id" "$p_cfg" 1 | grep -v '^$'
  exit 0
fi

[ -n "$JDKS" ] || usage_error "--jdks is required"
[ -n "$OUT" ] || usage_error "--out is required"
JDK_LIST="$(split_list "$JDKS")" || exit 2
for id in $JDK_LIST; do
  validate_jdk_id "$id"
  [ -n "$(catalog_aarch64 "$id")" ] || usage_error "no aarch64 catalog entry for $id"
done
CONFIG_LIST=""
while IFS=, read -r name _; do
  case "$name" in "" | \#* | config) continue ;; esac
  if [ -n "$ONLY_CONFIGS" ] && ! in_list "$name" "$ONLY_CONFIGS"; then continue; fi
  CONFIG_LIST="$CONFIG_LIST $name"
done <"$CONFIGS_FILE"
[ -n "$CONFIG_LIST" ] || die "no configurations selected"

require_cmd kubectl jq
init_tmpdir
mkdir -p "$OUT"
kubectl config current-context >"$OUT/kube-context.txt" || die "no current kubectl context"
kubectl apply -f "$SCRIPT_DIR/namespace.yaml" >/dev/null
kubectl create configmap jvmlab-src -n "$NAMESPACE" \
  --from-file="$SCRIPT_DIR/../java/ContainerProbe.java" \
  --from-file="$SCRIPT_DIR/../java/AllocPressure.java" \
  --from-file="$SCRIPT_DIR/../java/ThreadFootprint.java" \
  --from-file="$SCRIPT_DIR/extract_jdk.py" \
  --from-file="$SCRIPT_DIR/pod-fetch-jdk.sh" \
  --from-file="$SCRIPT_DIR/pod-run.sh" \
  --dry-run=client -o yaml >"$TMP_WORK/configmap.yaml"
kubectl apply -f "$TMP_WORK/configmap.yaml" >/dev/null
kubectl get nodes -o json >"$OUT/nodes.json"

# wait_pod_done POD: waits until the pod has phase Succeeded or Failed.
wait_pod_done() {
  local deadline phase
  deadline=$(($(date +%s) + TIMEOUT))
  while :; do
    phase="$(kubectl get pod "$1" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.phase // empty')"
    case "$phase" in Succeeded | Failed) return 0 ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

if [ "$NODEINFO" = 1 ]; then
  # nodeinfo-pod.yaml with the pod names nodeinfo-<os>-<family> and the instance-type selector
  # next to lab/os.
  awk -v fam="$FAMILY" -v itype="$INSTANCE_TYPE" '
    /^  name: nodeinfo-/ { print $0 "-" fam; next }
    /^    lab\/os: / { print; print "    node.kubernetes.io/instance-type: " itype; next }
    { print }' "$SCRIPT_DIR/nodeinfo-pod.yaml" >"$OUT/nodeinfo-pods.yaml"
  kubectl apply -f "$OUT/nodeinfo-pods.yaml" >/dev/null
  for os in $OS_LIST; do
    if wait_pod_done "nodeinfo-$os-$FAMILY"; then
      kubectl logs "nodeinfo-$os-$FAMILY" -n "$NAMESPACE" >"$OUT/nodeinfo-$os.txt" || warn "no log from nodeinfo-$os-$FAMILY"
    else
      warn "nodeinfo-$os-$FAMILY did not finish"
    fi
  done
  kubectl delete -f "$OUT/nodeinfo-pods.yaml" --wait=true >/dev/null || true
fi

# section FILE NAME: lines of FILE between "=== NAME" and the next "=== " line.
section() {
  awk -v s="=== $2" '$0 == s { on = 1; next } /^=== / { on = 0 } on' "$1"
}

# run_job OS JDK_ID CONFIG REPEAT SEQ: runs one Job (retried once if the init container
# fails, for example on a download error) and collects its results.
run_job() {
  local os="$1" id="$2" cfg="$3" rep="$4" seq="$5" dir name attempt=1 pod prog init_rc deadline
  dir="$OUT/$os/$id/$cfg/r$rep"
  mkdir -p "$dir"
  name="jvmlab-$os-$FAMILY-$seq"
  prog="$(config_row "$cfg" | cut -d, -f2)"
  while :; do
    render_job "$name" "$os" "$id" "$cfg" "$rep" | grep -v '^$' >"$dir/job.yaml"
    kubectl apply -f "$dir/job.yaml" >/dev/null || { warn "$name: kubectl apply failed"; return 1; }
    pod=""
    deadline=$(($(date +%s) + 120))
    while [ -z "$pod" ]; do
      pod="$(kubectl get pods -n "$NAMESPACE" -l "job-name=$name" -o json | jq -r '.items[0].metadata.name // empty')"
      [ -n "$pod" ] || { [ "$(date +%s)" -lt "$deadline" ] || break; sleep 2; }
    done
    if [ -z "$pod" ]; then
      warn "$name: no pod was created"
      kubectl delete job "$name" -n "$NAMESPACE" --wait=true >/dev/null || true
      return 1
    fi
    wait_pod_done "$pod" || warn "$name: pod $pod did not finish within $TIMEOUT s"
    kubectl get pod "$pod" -n "$NAMESPACE" -o json >"$dir/pod.json" || { warn "$name: cannot read pod $pod"; return 1; }
    kubectl logs "$pod" -n "$NAMESPACE" -c fetch-jdk >"$dir/init.log" 2>&1 || true
    init_rc="$(jq -r '.status.initContainerStatuses[0].state.terminated.exitCode // empty' "$dir/pod.json")"
    if [ "$init_rc" != 0 ] && [ "$attempt" -lt 2 ]; then
      warn "$name: init container failed (exit ${init_rc:-none}); retrying once"
      printf 'attempt %s: init exit %s\n' "$attempt" "${init_rc:-none}" >>"$dir/retries.txt"
      kubectl delete job "$name" -n "$NAMESPACE" --wait=true >/dev/null || true
      attempt=$((attempt + 1))
      continue
    fi
    break
  done
  if ! kubectl logs "$pod" -n "$NAMESPACE" -c probe >"$dir/logs.txt" 2>&1; then
    warn "$name: cannot read the logs of pod $pod (see $dir/logs.txt)"
    kubectl delete job "$name" -n "$NAMESPACE" --wait=true --cascade=foreground >/dev/null || true
    return 1
  fi
  section "$dir/logs.txt" container-log >"$dir/jvm-container.log"
  section "$dir/logs.txt" showsettings-system >"$dir/showsettings-system.txt"
  if [ "$prog" = probe ]; then
    section "$dir/logs.txt" probe | grep '^{' >"$dir/probe.json" || true
  else
    section "$dir/logs.txt" alloc >"$dir/alloc.log"
  fi
  kubectl delete job "$name" -n "$NAMESPACE" --wait=true --cascade=foreground >/dev/null || true
  return 0
}

# run_os OS: all runs of one node group, one at a time.
run_os() {
  local os="$1" seq=0 failed=0 id cfg prog n r
  for id in $JDK_LIST; do
    for cfg in $CONFIG_LIST; do
      prog="$(config_row "$cfg" | cut -d, -f2)"
      n="$REPEATS_PROBE"
      if [ "$prog" = alloc ]; then n="$REPEATS_ALLOC"; fi
      r=1
      while [ "$r" -le "$n" ]; do
        seq=$((seq + 1))
        info "== $os $id $cfg r$r"
        run_job "$os" "$id" "$cfg" "$r" "$seq" || failed=1
        r=$((r + 1))
      done
    done
  done
  return "$failed"
}

PIDS=""
for os in $OS_LIST; do
  run_os "$os" >"$OUT/run-$os.log" 2>&1 &
  PIDS="$PIDS $!"
done
FAILED=0
for p in $PIDS; do
  wait "$p" || FAILED=1
done
echo "Results: $OUT (logs: $OUT/run-<os>.log)"
exit "$FAILED"

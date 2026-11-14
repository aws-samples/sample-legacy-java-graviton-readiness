#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Test cases for the cgroup-lab scripts (docker and EKS). Sourced by tests/run-tests.sh.
# shellcheck disable=SC2034  # STUB_ENV is read by run_script in tests/run-tests.sh

IMAGE_PINNED="public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:381352c430f36d8aa6b8b670de06e7e4e5642fe0cb9dbd463bb8d1e79aefc0c7"

# ---- cgroup-lab/docker/run-docker-matrix.sh ----------------------------------------------------
test_docker_matrix_dry_run() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.362.08.1" 1.8.0_362
  stub_env STUB_UNAME_S=Darwin
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --configs D2,A3 --repeats 1 --alloc-repeats 1 --dry-run
  assert_exit 0
  assert_contains "--network none --read-only --tmpfs /tmp:rw,size=64m --user 10001:10001 --cap-drop ALL --security-opt no-new-privileges"
  assert_contains "-v $CASE_DIR/jdks/corretto-8.362.08.1:/jdk:ro"
  assert_contains "--memory=1g --cpus=2 $IMAGE_PINNED /jdk/bin/java -cp /probe ContainerProbe"
  assert_contains "--memory=1g --cpus=2 $IMAGE_PINNED /jdk/bin/java -Xmx768m -cp /probe AllocPressure"
  assert_contains "/jdk/bin/java -XX:+UnlockDiagnosticVMOptions -XX:+PrintContainerInfo -version"
  assert_contains "/jdk/bin/java -Xmx768m -XshowSettings:system -version"
  assert_contains "Dry run: nothing was run."
  assert_not_contains "D0"
  assert_not_called "docker "
  [ ! -e "$CASE_DIR/out" ] || fail "dry run created the result directory"
}

test_docker_matrix_run() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  stub_env STUB_OOM=1
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --configs D2,A1 --repeats 2 --alloc-repeats 1 --cgroup-label v2
  assert_exit 0
  local d="$CASE_DIR/out/c9g/v2/corretto-8.372.07.1"
  assert_file "$d/D2/r1/probe.json"
  assert_file "$d/D2/r2/meta.json"
  assert_file_contains "$d/D2/r1/jvm-container.log" 'openjdk version "1.8.0_372"'
  jq -e '.config == "D2" and .exit_code == 0 and .oom_killed == false and .docker_flags == "--memory=1g --cpus=2"' \
    "$d/D2/r1/meta.json" >/dev/null || fail "D2 meta.json: $(cat "$d/D2/r1/meta.json")"
  jq -e '.config == "A1" and .exit_code == 137 and .oom_killed == true and .program == "alloc"' \
    "$d/A1/r1/meta.json" >/dev/null || fail "A1 meta.json: $(cat "$d/A1/r1/meta.json")"
  assert_file_contains "$d/A1/r1/alloc.log" '"event":"start"'
  assert_file_contains "$d/A1/r1/kernel-oom.log" "oom-kill"
  [ ! -e "$d/D2/r1/kernel-oom.log" ] || fail "kernel OOM log written for a probe run"
  assert_called "journalctl -k --no-pager --since @"
  assert_called "docker rm -f jvmlab-"
  [ "$(grep -c '^docker run --name' "$STUB_LOG")" = 3 ] || fail "expected 3 measured container runs"
}

test_docker_matrix_refuses() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  stub_env STUB_UNAME_S=Darwin
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g
  assert_exit 1
  assert_contains "this lab runs on a Linux host"
  STUB_ENV=(STUB_DOCKER_DOWN=1)
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g
  assert_exit 1
  assert_contains "docker info failed"
  printf 'config,program,docker_flags,jvm_flags,description\nX1,probe,--privileged,,bad\n' >"$CASE_DIR/bad.csv"
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g \
    --configs-file "$CASE_DIR/bad.csv" --dry-run
  assert_exit 2
  assert_contains "unsupported docker flag '--privileged'"
  printf 'config,program,docker_flags,jvm_flags,description\nX1,probe,,-XX:OnError=sh,bad\n' >"$CASE_DIR/bad.csv"
  run_script cgroup-lab/docker/run-docker-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g \
    --configs-file "$CASE_DIR/bad.csv" --dry-run
  assert_exit 2
  assert_contains "unsupported JVM flag"
  assert_not_called "docker run"
}

# ---- cgroup-lab/docker/run-thread-matrix.sh ----------------------------------------------------
test_thread_matrix_dry_run() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  stub_env STUB_UNAME_S=Darwin
  run_script cgroup-lab/docker/run-thread-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --thp-modes always --threads 0,200 --xss default,1m --repeats 1 --dry-run
  assert_exit 0
  assert_contains "echo always > /sys/kernel/mm/transparent_hugepage/enabled"
  assert_contains "--memory=4g $IMAGE_PINNED /jdk/bin/java -XX:NativeMemoryTracking=summary -XX:+UnlockDiagnosticVMOptions -XX:+PrintNMTStatistics -cp /probe ThreadFootprint --threads 200 --samples 5,30"
  assert_contains "-XX:+PrintNMTStatistics -Xss1m -cp /probe ThreadFootprint --threads 0"
  [ "$(grep -c 'ThreadFootprint' "$OUT")" = 4 ] || fail "expected 4 cells"
  run_script cgroup-lab/docker/run-thread-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --oom-demo --dry-run
  assert_exit 0
  assert_contains "--memory=1g $IMAGE_PINNED"
  assert_contains "--threads 1000 --samples 5,30"
  [ "$(grep -c 'ThreadFootprint' "$OUT")" = 5 ] || fail "expected 5 OOM demo runs"
  assert_not_called "docker "
  run_script cgroup-lab/docker/run-thread-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --thp-modes sometimes --dry-run
  assert_exit 2
  run_script cgroup-lab/docker/run-thread-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --xss 1g --dry-run
  assert_exit 2
}

test_thread_matrix_run_restores_thp() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  printf 'always\n' >"$CASE_DIR/thp-enabled"
  printf 'madvise\n' >"$CASE_DIR/defrag"
  stub_env THREAD_LAB_THP_FILE="$CASE_DIR/thp-enabled"
  run_script cgroup-lab/docker/run-thread-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" \
    --host-label c9g --thp-modes never --threads 200 --xss 1m --repeats 1
  assert_exit 0
  assert_contains "THP mode restored to always"
  [ "$(cat "$CASE_DIR/thp-enabled")" = always ] || fail "THP mode not restored: $(cat "$CASE_DIR/thp-enabled")"
  local d="$CASE_DIR/out/c9g/never/corretto-8.372.07.1/200-1m/r1"
  assert_file_contains "$d/footprint.json" '"event":"sample"'
  assert_file_contains "$d/nmt.txt" "Native Memory Tracking:"
  if grep -q '^{' "$d/nmt.txt"; then fail "JSON lines in nmt.txt"; fi
  jq -e '.thp == "never" and .xss == "1m" and .threads == 200 and .memory == "4g"' "$d/meta.json" >/dev/null ||
    fail "meta.json: $(cat "$d/meta.json")"
  assert_file_contains "$CASE_DIR/out/c9g/never/thp.txt" "enabled: never"
  assert_called "-Xss1m -cp /probe ThreadFootprint --threads 200 --samples 5,30"
}

# ---- cgroup-lab/eks/eks-up.sh and eks-down.sh -------------------------------------------------
EKS_UP=(--region us-east-1 --owner example-owner --run-id test-run-1 --k8s-version 1.34)

test_eks_up_print_config() {
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --print-config
  assert_exit 0
  assert_contains "name: jvm-cgroup-test-run-1"
  assert_contains 'version: "1.34"'
  assert_contains "gateway: Disable"
  assert_contains "name: al2023-m8g"
  assert_contains "name: br-m8g"
  assert_contains "name: al2023-m9g"
  assert_contains "name: br-m9g"
  [ "$(grep -c 'amiFamily: AmazonLinux2023' "$OUT")" = 2 ] || fail "expected 2 AL2023 node groups"
  [ "$(grep -c 'amiFamily: Bottlerocket' "$OUT")" = 2 ] || fail "expected 2 Bottlerocket node groups"
  [ "$(grep -c 'instanceType: m8g.xlarge' "$OUT")" = 2 ] || fail "expected 2 m8g.xlarge node groups"
  [ "$(grep -c 'instanceType: m9g.xlarge' "$OUT")" = 2 ] || fail "expected 2 m9g.xlarge node groups"
  [ "$(grep -c 'disableIMDSv1: true' "$OUT")" = 4 ] || fail "IMDSv1 not disabled on every node group"
  [ "$(grep -c 'volumeEncrypted: true' "$OUT")" = 4 ] || fail "volumes not encrypted on every node group"
  assert_contains "run-id: test-run-1"
  assert_contains "owner: example-owner"
  assert_contains "disableIMDSv1: true"
  assert_not_contains "publicAccessCIDRs"
  assert_not_contains "__"
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --print-config --api-allowed-cidr 203.0.113.10/32
  assert_contains 'publicAccessCIDRs: ["203.0.113.10/32"]'
  assert_not_called "eksctl "
  assert_not_called "aws "
}

test_eks_up_dry_run_and_create() {
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --dry-run
  assert_exit 0
  assert_called "eksctl create cluster -f - --dry-run"
  assert_file_contains "$CASE_DIR/eksctl-config.yaml" "gateway: Disable"
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}"
  assert_exit 1
  assert_contains "stdin is not a terminal"
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --yes --kubeconfig "$CASE_DIR/kubeconfig"
  assert_exit 0
  assert_called "eksctl create cluster -f - --kubeconfig $CASE_DIR/kubeconfig"
}

test_eks_up_invalid() {
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --instance-type m8g.xlarge --print-config
  assert_exit 2
  assert_contains "unknown argument '--instance-type'"
  run_script cgroup-lab/eks/eks-up.sh --region us-east-1 --run-id test-run-1 --k8s-version 1.34 --print-config
  assert_exit 2
  assert_contains "--owner is required"
  run_script cgroup-lab/eks/eks-up.sh "${EKS_UP[@]}" --api-allowed-cidr 203.0.113.300/32 --print-config
  assert_exit 2
}

test_eks_down_delegates() {
  stub_env STUB_WORLD=present
  run_script cgroup-lab/eks/eks-down.sh --region us-east-1 --run-id test-run-1
  assert_exit 1
  assert_contains "eks-cluster       jvm-cgroup-test-run-1"
  assert_contains "Dry run: nothing was deleted."
  assert_not_called "eksctl delete"
  run_script cgroup-lab/eks/eks-down.sh --region us-east-1 --run-id test-run-1 --execute --yes
  assert_exit 0
  assert_called "eksctl delete cluster --name jvm-cgroup-test-run-1 --region us-east-1 --wait"
  assert_contains "Nothing of run test-run-1 remains."
}

# ---- cgroup-lab/eks/run-eks-matrix.sh ---------------------------------------------------------
test_eks_print_job_matches_example() {
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --print-job al2023,corretto-8.372.07.1,K2
  assert_exit 0
  grep -v '^#' "$REPO_DIR/cgroup-lab/eks/example-job.yaml" >"$CASE_DIR/example.yaml"
  diff "$CASE_DIR/example.yaml" "$OUT" >/dev/null || fail "example-job.yaml differs from --print-job output"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m9g.xlarge --print-job bottlerocket,temurin-8u362-b09,K3
  assert_exit 0
  assert_contains "name: jvmlab-bottlerocket-m9g-example"
  assert_contains "lab/os: bottlerocket"
  assert_contains "node.kubernetes.io/instance-type: m9g.xlarge"
  assert_contains "value: \"9290a8beefd7a94f0eb030f62d402411a852100482b9c5b63714bacc57002c2a\""
  # K3: CPU request without a CPU limit; the main container has only a memory limit
  awk '/^      containers:/ { on = 1 } on' "$OUT" | awk '/limits:/ { l = 1; next } l && /cpu:/ { bad = 1 } l && /securityContext:/ { exit } END { exit bad }' ||
    fail "K3 main container has a CPU limit"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --print-job al2023,corretto-8.000.00.0,K1
  assert_exit 1
  assert_contains "no aarch64 catalog entry"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --print-job windows,corretto-8.372.07.1,K1
  assert_exit 2
  run_script cgroup-lab/eks/run-eks-matrix.sh --print-job al2023,corretto-8.372.07.1,K2
  assert_exit 2
  assert_contains "--instance-type is required"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8i.xlarge --print-job al2023,corretto-8.372.07.1,K2
  assert_exit 2
  assert_contains "is not an arm64"
  assert_not_called "kubectl "
}

# whole_cpu_limits FILE: every "cpu:" under "limits:" is a whole number of CPUs.
whole_cpu_limits() {
  awk '/limits:/ { l = 1; next }
    l && /cpu:/ { v = $2; gsub(/"/, "", v); if (v !~ /^[0-9]+$/) bad = 1; next }
    l && !/memory:/ { l = 0 }
    END { exit bad }' "$1"
}
test_eks_manifests_network_policy() {
  local eks="$REPO_DIR/cgroup-lab/eks" ns="$REPO_DIR/cgroup-lab/eks/namespace.yaml"
  [ "$(grep '^kind:' "$ns" | tr '\n' ' ')" = "kind: Namespace kind: NetworkPolicy " ] ||
    fail "namespace.yaml must hold the Namespace, then the NetworkPolicy"
  assert_file_contains "$ns" "pod-security.kubernetes.io/enforce: restricted"
  # NetworkPolicy: all pods of the namespace, no ingress rule (deny all), egress allowed
  awk '/^kind: NetworkPolicy/ { on = 1 } on' "$ns" >"$CASE_DIR/netpol.yaml"
  assert_file_contains "$CASE_DIR/netpol.yaml" "  namespace: jvm-cgroup-lab"
  assert_file_contains "$CASE_DIR/netpol.yaml" "  podSelector: {}"
  assert_file_contains "$CASE_DIR/netpol.yaml" "    - Ingress"
  assert_file_contains "$CASE_DIR/netpol.yaml" "    - Egress"
  [ "$(awk '/^  egress:/ { getline; print }' "$CASE_DIR/netpol.yaml")" = "    - {}" ] || fail "egress is not allowed to all destinations"
  ! grep -q 'ingress:' "$CASE_DIR/netpol.yaml" || fail "the NetworkPolicy has an ingress rule"
  # the lab's pods are in the namespace of the NetworkPolicy
  for f in nodeinfo-pod.yaml example-job.yaml; do
    [ "$(grep -c '^  namespace: ' "$eks/$f")" = "$(grep -c '^  namespace: jvm-cgroup-lab$' "$eks/$f")" ] ||
      fail "$f has a pod outside jvm-cgroup-lab"
  done
  # whole-CPU limits only (fractional CPU limits throttle); the nodeinfo pods keep a 100m request
  whole_cpu_limits "$eks/nodeinfo-pod.yaml" || fail "nodeinfo-pod.yaml has a fractional CPU limit"
  whole_cpu_limits "$eks/example-job.yaml" || fail "example-job.yaml has a fractional CPU limit"
  [ "$(grep -c '^          cpu: "1"$' "$eks/nodeinfo-pod.yaml")" = 2 ] || fail "nodeinfo pods without a CPU limit of 1"
  [ "$(grep -c '^          cpu: 100m$' "$eks/nodeinfo-pod.yaml")" = 2 ] || fail "nodeinfo pods without a CPU request of 100m"
  # runAsNonRoot on the pod and on every container
  [ "$(grep -c 'runAsNonRoot: true$' "$eks/nodeinfo-pod.yaml")" = 4 ] || fail "nodeinfo pods: runAsNonRoot missing"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m9g.xlarge --print-job bottlerocket,corretto-8.372.07.1,K1
  assert_exit 0
  assert_contains "namespace: jvm-cgroup-lab"
  whole_cpu_limits "$OUT" || fail "rendered Job has a fractional CPU limit"
  [ "$(grep -c 'runAsNonRoot: true$' "$OUT")" = 3 ] || fail "rendered Job: runAsNonRoot missing"
}

test_eks_matrix_run() {
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m9g.xlarge --jdks corretto-8.372.07.1 --configs K1,K6 --nodegroups al2023 \
    --repeats-probe 1 --repeats-alloc 1 --out "$CASE_DIR/out" --timeout 60
  assert_exit 0
  local d="$CASE_DIR/out/al2023/corretto-8.372.07.1"
  assert_file_contains "$d/K1/r1/probe.json" '"probe":"ContainerProbe"'
  assert_file_contains "$d/K1/r1/jvm-container.log" "OSContainer::init"
  assert_file_contains "$d/K1/r1/showsettings-system.txt" "Provider: cgroupv2"
  assert_file "$d/K1/r1/pod.json"
  assert_file "$d/K1/r1/init.log"
  assert_file_contains "$d/K6/r1/alloc.log" '"event":"start"'
  assert_file_contains "$d/K6/r1/job.yaml" "value: alloc"
  assert_file "$CASE_DIR/out/nodes.json"
  assert_file_contains "$CASE_DIR/out/nodeinfo-al2023.txt" "cgroup_fs: cgroup2fs"
  [ ! -e "$CASE_DIR/out/bottlerocket" ] || fail "bottlerocket ran although not selected"
  assert_called "kubectl apply -f $REPO_DIR/cgroup-lab/eks/namespace.yaml"
  assert_called "kubectl create configmap jvmlab-src -n jvm-cgroup-lab"
  assert_called "kubectl delete job jvmlab-al2023-m9g-1 -n jvm-cgroup-lab --wait=true --cascade=foreground"
  assert_file_contains "$d/K1/r1/job.yaml" "node.kubernetes.io/instance-type: m9g.xlarge"
  assert_order "kubectl apply -f $CASE_DIR/out/nodeinfo-pods.yaml" "kubectl apply -f $CASE_DIR/out/al2023"
  assert_called "kubectl get pod nodeinfo-al2023-m9g -n jvm-cgroup-lab"
  local ni="$CASE_DIR/out/nodeinfo-pods.yaml"
  assert_file_contains "$ni" "name: nodeinfo-al2023-m9g"
  assert_file_contains "$ni" "name: nodeinfo-bottlerocket-m9g"
  [ "$(grep -c '^    node.kubernetes.io/instance-type: m9g.xlarge$' "$ni")" = 2 ] || fail "nodeinfo pods without the instance-type selector"
}

test_eks_matrix_retries_init_once() {
  stub_env STUB_INIT_FAIL_ONCE=1
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --jdks corretto-8.372.07.1 --configs K1 --nodegroups al2023 \
    --repeats-probe 1 --out "$CASE_DIR/out" --skip-nodeinfo
  assert_exit 0
  assert_file_contains "$CASE_DIR/out/al2023/corretto-8.372.07.1/K1/r1/retries.txt" "attempt 1: init exit 6"
  [ "$(grep -c '^kubectl apply -f .*/job.yaml' "$STUB_LOG")" = 2 ] || fail "expected 2 Job applies"
  assert_not_called "nodeinfo-pods.yaml"
}

test_eks_matrix_logs_fail() {
  stub_env STUB_PROBE_LOGS_FAIL=1
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m9g.xlarge --jdks corretto-8.372.07.1 --configs K1 --nodegroups al2023 \
    --repeats-probe 1 --out "$CASE_DIR/out" --skip-nodeinfo
  assert_exit 1
  assert_file_contains "$CASE_DIR/out/run-al2023.log" "jvmlab-al2023-m9g-1: cannot read the logs of pod jvmlab-al2023-m9g-1-abcde"
  assert_file_contains "$CASE_DIR/out/al2023/corretto-8.372.07.1/K1/r1/logs.txt" "TLS handshake timeout"
  assert_called "kubectl delete job jvmlab-al2023-m9g-1 -n jvm-cgroup-lab --wait=true --cascade=foreground"
}
test_eks_matrix_invalid() {
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --jdks corretto-8.000.00.0 --out "$CASE_DIR/out"
  assert_exit 2
  assert_contains "no aarch64 catalog entry"
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --jdks corretto-8.372.07.1 --configs D1 --out "$CASE_DIR/out"
  assert_exit 2
  run_script cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge --out "$CASE_DIR/out"
  assert_exit 2
  assert_contains "--jdks is required"
  run_script cgroup-lab/eks/run-eks-matrix.sh --jdks corretto-8.372.07.1 --out "$CASE_DIR/out"
  assert_exit 2
  assert_contains "--instance-type is required"
  assert_not_called "kubectl "
}

# ---- cgroup-lab/eks/extract_jdk.py ------------------------------------------------------------
# make_tar FILE MEMBER... : MEMBER is name, name=>linktarget (symlink) or dir/ (directory).
make_tar() {
  python3 - "$@" <<'EOF'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for spec in sys.argv[2:]:
        if "=>" in spec:
            name, target = spec.split("=>", 1)
            info = tarfile.TarInfo(name); info.type = tarfile.SYMTYPE; info.linkname = target
            t.addfile(info)
        elif spec.endswith("/"):
            info = tarfile.TarInfo(spec.rstrip("/")); info.type = tarfile.DIRTYPE; info.mode = 0o755
            t.addfile(info)
        else:
            data = b"#!/bin/sh\n"
            info = tarfile.TarInfo(spec); info.size = len(data); info.mode = 0o755
            t.addfile(info, io.BytesIO(data))
EOF
}

test_extract_jdk_py() {
  local py="cgroup-lab/eks/extract_jdk.py"
  make_tar "$CASE_DIR/good.tgz" jdk/ jdk/bin/ jdk/bin/java jdk/lib/legal/ "jdk/lib/legal/LICENSE=>../../bin/java"
  OUT="$CASE_DIR/py.txt"
  PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_DIR/$py" "$CASE_DIR/good.tgz" "$CASE_DIR/x" >"$OUT" 2>&1 || fail "good tarball rejected"
  [ -x "$CASE_DIR/x/bin/java" ] || fail "bin/java not extracted"
  [ -L "$CASE_DIR/x/lib/legal/LICENSE" ] || fail "symlink not created"
  local spec
  for spec in "jdk/../../evil" "/abs/file" "jdk/lib/escape=>../../../outside" "jdk/lib/abs=>/etc/passwd"; do
    make_tar "$CASE_DIR/bad.tgz" jdk/ jdk/bin/java "$spec"
    rm -rf "$CASE_DIR/y"
    if PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_DIR/$py" "$CASE_DIR/bad.tgz" "$CASE_DIR/y" >"$OUT" 2>&1; then
      fail "accepted a tarball with $spec"
    fi
    [ ! -e "$CASE_DIR/y" ] || fail "wrote files for a rejected tarball ($spec)"
  done
  if PYTHONDONTWRITEBYTECODE=1 python3 "$REPO_DIR/$py" "$CASE_DIR/good.tgz" "$CASE_DIR/x" >"$OUT" 2>&1; then
    fail "extracted into an existing destination"
  fi
}

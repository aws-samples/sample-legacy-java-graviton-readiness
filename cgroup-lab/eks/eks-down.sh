#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Deletes the EKS test cluster of the cgroup lab. Delegates to infra/cleanup.sh, which checks
# that the cluster carries the run's tags before eksctl deletes it, and verifies afterwards.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --run-id RUN_ID [--cluster-name NAME] [--execute [--yes]]
                    [--profile PROFILE]

Runs infra/cleanup.sh --eks-cluster NAME --verify. Without --execute it prints the plan only.
The default cluster name is jvm-cgroup-<run-id>. The EC2 resources of the same run ID (if
any) are part of the same plan.

Exit codes: those of infra/cleanup.sh (0 success, 1 runtime error or resources remaining,
2 usage error).
EOF
}

REGION="${AWS_REGION:-}"
RUN_ID=""
CLUSTER=""
PASS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --cluster-name) need_arg "$@"; CLUSTER="$2"; shift 2 ;;
    --profile) need_arg "$@"; PASS+=(--profile "$2"); shift 2 ;;
    --execute) PASS+=(--execute); shift ;;
    --yes) PASS+=(--yes); shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
validate_run_id "$RUN_ID"
CLUSTER="${CLUSTER:-jvm-cgroup-$RUN_ID}"
validate_cluster_name "$CLUSTER"

exec bash "$REPO_ROOT/infra/cleanup.sh" --region "$REGION" --run-id "$RUN_ID" \
  --eks-cluster "$CLUSTER" --verify ${PASS[@]+"${PASS[@]}"}

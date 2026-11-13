#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Creates the EKS test cluster of the cgroup lab with eksctl from cluster.yaml.tmpl: one
# Amazon Linux 2023 node and one Bottlerocket node on m8g.xlarge (AWS Graviton4) and on
# m9g.xlarge (AWS Graviton5), tagged with project, owner and run-id. Delete it with
# eks-down.sh as soon as the runs are done.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.sh
. "$SCRIPT_DIR/../../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --owner OWNER --run-id RUN_ID --k8s-version VERSION [options]

Creates (billable): an EKS control plane, a VPC with public subnets (no NAT gateway), four
managed node groups with one node each (al2023-m8g, br-m8g on m8g.xlarge; al2023-m9g,
br-m9g on m9g.xlarge), and the IAM roles, security groups and CloudFormation stacks that
eksctl creates for them. Edit cluster.yaml.tmpl to use other arm64 instance types.

Required:
  --region REGION         AWS Region
  --owner OWNER           Value of the owner tag
  --run-id RUN_ID         Value of the run-id tag; the default cluster name is jvm-cgroup-<run-id>
  --k8s-version VERSION   Kubernetes minor version in EKS standard support, for example 1.34

Options:
  --cluster-name NAME     Cluster name (default: jvm-cgroup-<run-id>)
  --api-allowed-cidr CIDR Allow the public API endpoint only from CIDR, for example your
                          address with /32. Without it, eksctl's default applies and the
                          endpoint accepts requests from all addresses (authentication is
                          still required).
  --kubeconfig PATH       Where eksctl writes the kubeconfig (default: eksctl's default)
  --profile PROFILE       AWS CLI profile
  --print-config          Print the rendered ClusterConfig; no AWS calls
  --dry-run               Print the config and run eksctl create cluster --dry-run
  --yes                   Do not ask for confirmation
  -h, --help              Show this help

Exit codes: 0 success, 1 runtime error, 2 usage error.
EOF
}

REGION="${AWS_REGION:-}"
OWNER=""
RUN_ID=""
K8S_VERSION=""
CLUSTER=""
API_CIDR=""
KUBECONFIG_PATH=""
PROFILE=""
PRINT_ONLY=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --owner) need_arg "$@"; OWNER="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --k8s-version) need_arg "$@"; K8S_VERSION="$2"; shift 2 ;;
    --cluster-name) need_arg "$@"; CLUSTER="$2"; shift 2 ;;
    --api-allowed-cidr) need_arg "$@"; API_CIDR="$2"; shift 2 ;;
    --kubeconfig) need_arg "$@"; KUBECONFIG_PATH="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    --print-config) PRINT_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$OWNER" ] || usage_error "--owner is required"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
[ -n "$K8S_VERSION" ] || usage_error "--k8s-version is required"
validate_region "$REGION"
validate_owner "$OWNER"
validate_run_id "$RUN_ID"
validate_k8s_version "$K8S_VERSION"
CLUSTER="${CLUSTER:-jvm-cgroup-$RUN_ID}"
validate_cluster_name "$CLUSTER"
if [ -n "$API_CIDR" ]; then validate_cidr "$API_CIDR"; fi
if [ -n "$KUBECONFIG_PATH" ]; then
  _matches "$KUBECONFIG_PATH" '^[A-Za-z0-9._/~-]+$' || usage_error "invalid --kubeconfig path"
fi
if [ -n "$PROFILE" ]; then validate_profile "$PROFILE"; fi

# All substituted values are validated above and contain no "|" or newline.
render() {
  local tmpl="$SCRIPT_DIR/cluster.yaml.tmpl"
  if [ -n "$API_CIDR" ]; then
    sed -e "s|__API_CIDR__|$API_CIDR|" "$tmpl"
  else
    sed -e '/__API_CIDR__/d' "$tmpl"
  fi | sed -e "s|__CLUSTER__|$CLUSTER|" -e "s|__REGION__|$REGION|" \
    -e "s|__K8S_VERSION__|$K8S_VERSION|" -e "s|__OWNER__|$OWNER|g" -e "s|__RUN_ID__|$RUN_ID|g"
}

if [ "$PRINT_ONLY" = 1 ]; then
  render
  exit 0
fi

require_cmd eksctl aws jq
setup_aws_env "$PROFILE" "$REGION"
EKSCTL_ARGS=(create cluster -f -)
if [ -n "$KUBECONFIG_PATH" ]; then EKSCTL_ARGS+=(--kubeconfig "$KUBECONFIG_PATH"); fi

if [ "$DRY_RUN" = 1 ]; then
  render
  echo "---"
  render | eksctl "${EKSCTL_ARGS[@]}" --dry-run
  echo "Dry run: nothing was created."
  exit 0
fi
show_identity
render
if [ -z "$API_CIDR" ]; then
  warn "no --api-allowed-cidr given: the public API endpoint accepts requests from all addresses (authentication is still required)"
fi
echo "This creates an EKS cluster $CLUSTER, a VPC and four nodes (billable, about 20 minutes)."
confirm yes
render | eksctl "${EKSCTL_ARGS[@]}"
echo "Next: cgroup-lab/eks/run-eks-matrix.sh ...; then cgroup-lab/eks/eks-down.sh --region $REGION --run-id $RUN_ID --cluster-name $CLUSTER --execute"

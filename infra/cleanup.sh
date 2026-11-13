#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Deletes the resources of one lab run: the EKS test cluster (optional), EC2 instances,
# leftover EBS volumes, the security group, key pairs, the IAM role and instance profile,
# and the S3 bucket. Only resources that carry the tags project=<sample> and run-id=<run-id>
# are deleted. Dry run by default; deletes only with --execute. --verify lists everything of
# the run that still exists and exits with 1 if anything remains.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --run-id RUN_ID [--eks-cluster NAME]
                    [--execute [--yes]] [--verify [--verify-out FILE]] [--profile PROFILE]

Without --execute, prints the cleanup plan and deletes nothing. With --execute, deletes in
this order: EKS cluster (eksctl delete cluster --wait), instances (terminate and wait),
available EBS volumes, security groups, key pairs, IAM instance profile and role, S3 bucket
(objects first). Resources without the tags $SAMPLE_TAG_KEY=$SAMPLE_TAG_VALUE and
$RUN_ID_TAG_KEY=<run-id> are reported and kept. Instances, volumes and security groups that
belong to an EKS cluster (its nodes and the security groups eksctl created) are reported and
kept; eksctl deletes them with the cluster.

Options:
  --region REGION       AWS Region
  --run-id RUN_ID       Run ID used with infra/ec2-up.sh and cgroup-lab/eks/eks-up.sh
  --eks-cluster NAME    Also delete this EKS cluster (it must carry the run's tags)
  --execute             Delete the resources marked "delete" in the plan
  --yes                 With --execute: do not ask for confirmation
  --verify              After the plan (and the deletion, with --execute), list every
                        resource of the run that still exists: EC2 instances that are not
                        terminated, EBS volumes, snapshots, AMIs, security groups, key pairs,
                        NAT gateways, Elastic IPs, EKS clusters, CloudFormation stacks
                        eksctl-<cluster>-*, IAM roles and instance profiles, the S3 bucket,
                        and anything else the Resource Groups Tagging API reports. EC2
                        instances, volumes and network interfaces that the tagging API still
                        lists are checked with describe-*; deleted ones (and terminated
                        instances) are printed as "listed by the tagging API but already
                        deleted" and do not count
  --verify-out FILE     Write the verification result as JSON
  --profile PROFILE     AWS CLI profile
  -h, --help            Show this help

Exit codes: 0 success (and, with --verify, nothing remains), 1 runtime error or resources
remaining, 2 usage error.
EOF
}

REGION="${AWS_REGION:-}"
RUN_ID=""
CLUSTER=""
EXECUTE=0
VERIFY=0
VERIFY_OUT=""
PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --eks-cluster) need_arg "$@"; CLUSTER="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --verify-out) need_arg "$@"; VERIFY_OUT="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
validate_region "$REGION"
validate_run_id "$RUN_ID"
if [ -n "$CLUSTER" ]; then validate_cluster_name "$CLUSTER"; fi
if [ -n "$PROFILE" ]; then validate_profile "$PROFILE"; fi
if [ -n "$VERIFY_OUT" ] && [ "$VERIFY" = 0 ]; then usage_error "--verify-out needs --verify"; fi

require_cmd aws jq
if [ -n "$CLUSTER" ] && [ "$EXECUTE" = 1 ]; then require_cmd eksctl; fi
setup_aws_env "$PROFILE" "$REGION"
init_tmpdir

BUCKET="$(bucket_name "$RUN_ID")"
ROLE="$(role_name "$RUN_ID")"
FILTERS=("Name=tag:$SAMPLE_TAG_KEY,Values=$SAMPLE_TAG_VALUE" "Name=tag:$RUN_ID_TAG_KEY,Values=$RUN_ID")

# ---- build the plan (parallel arrays) ---------------------------------------------------------
P_KIND=()
P_ID=()
P_ACTION=()
add_plan() {
  P_KIND+=("$1")
  P_ID+=("$2")
  P_ACTION+=("$3")
}
ids_of() { # ids_of JQ_EXPR: IDs from AWS_OUT, one per line
  printf '%s' "$AWS_OUT" | jq -r "$1"
}
# eks_split JQ_ITEMS ID_FIELD: prints ID=CLUSTER for each item of AWS_OUT, where CLUSTER is the
# EKS cluster the item belongs to (empty if none). The nodes, node volumes and security groups
# of the run's EKS cluster carry the run's tags too; eksctl deletes them with the cluster, and
# deleting them here would break a running cluster.
eks_split() {
  printf '%s' "$AWS_OUT" | jq -r --arg f "$2" '
    def eks: [(.Tags // [])[] | select(.Key == "eks:cluster-name" or .Key == "aws:eks:cluster-name"
      or .Key == "alpha.eksctl.io/cluster-name") | .Value][0] // "";
    '"$1"' | "\(.[$f])=\(eks)"'
}
eks_skip() { printf 'skip (part of EKS cluster %s; eksctl deletes it with the cluster)' "$1"; }

EKS_DELETE=0
if [ -n "$CLUSTER" ]; then
  if aws_lookup eks describe-cluster --name "$CLUSTER"; then
    if printf '%s' "$AWS_OUT" | jq -c '.cluster.tags // {}' | has_run_tags "$RUN_ID"; then
      add_plan eks-cluster "$CLUSTER" delete
      EKS_DELETE=1
    else
      add_plan eks-cluster "$CLUSTER" "skip (not tagged for run $RUN_ID)"
    fi
  else
    add_plan eks-cluster "$CLUSTER" absent
  fi
fi

INSTANCES=()
aws_lookup ec2 describe-instances --filters "${FILTERS[@]}" \
  Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down
for row in $(eks_split '.Reservations[].Instances[]' InstanceId); do
  id="${row%%=*}"
  if [ -n "${row#*=}" ]; then
    add_plan instance "$id" "$(eks_skip "${row#*=}")"
  else
    add_plan instance "$id" delete
    INSTANCES+=("$id")
  fi
done

aws_lookup ec2 describe-volumes --filters "${FILTERS[@]}"
for row in $(eks_split '.Volumes[]' VolumeId); do
  id="${row%%=*}"
  if [ -n "${row#*=}" ]; then
    add_plan volume "$id" "$(eks_skip "${row#*=}")"
  elif [ "$(ids_of ".Volumes[] | select(.VolumeId == \"$id\") | .State")" = available ]; then
    add_plan volume "$id" delete
  else
    add_plan volume "$id" "delete after its instance terminates (if it remains)"
  fi
done

aws_lookup ec2 describe-security-groups --filters "${FILTERS[@]}"
for row in $(eks_split '.SecurityGroups[]' GroupId); do
  id="${row%%=*}"
  if [ -n "${row#*=}" ]; then
    add_plan security-group "$id" "$(eks_skip "${row#*=}")"
  else
    add_plan security-group "$id" delete
  fi
done

aws_lookup ec2 describe-key-pairs --filters "${FILTERS[@]}"
for id in $(ids_of '.KeyPairs[].KeyPairId'); do add_plan key-pair "$id" delete; done

PROFILE_DELETE=0
if aws_lookup iam get-instance-profile --instance-profile-name "$ROLE"; then
  if printf '%s' "$AWS_OUT" | jq -c '.InstanceProfile.Tags // []' | has_run_tags "$RUN_ID"; then
    add_plan instance-profile "$ROLE" delete
    PROFILE_DELETE=1
  else
    add_plan instance-profile "$ROLE" "skip (not tagged for run $RUN_ID)"
  fi
else
  add_plan instance-profile "$ROLE" absent
fi
ROLE_DELETE=0
if aws_lookup iam get-role --role-name "$ROLE"; then
  if printf '%s' "$AWS_OUT" | jq -c '.Role.Tags // []' | has_run_tags "$RUN_ID"; then
    add_plan iam-role "$ROLE" delete
    ROLE_DELETE=1
  else
    add_plan iam-role "$ROLE" "skip (not tagged for run $RUN_ID)"
  fi
else
  add_plan iam-role "$ROLE" absent
fi

BUCKET_DELETE=0
if aws_lookup s3api head-bucket --bucket "$BUCKET"; then
  if aws_lookup s3api get-bucket-tagging --bucket "$BUCKET" &&
    printf '%s' "$AWS_OUT" | jq -c '.TagSet' | has_run_tags "$RUN_ID"; then
    add_plan s3-bucket "$BUCKET" delete
    BUCKET_DELETE=1
  else
    add_plan s3-bucket "$BUCKET" "skip (not tagged for run $RUN_ID)"
  fi
else
  add_plan s3-bucket "$BUCKET" absent
fi

show_identity
echo "Cleanup plan (Region $REGION, run ID $RUN_ID):"
DELETE_COUNT=0
i=0
while [ "$i" -lt "${#P_KIND[@]}" ]; do
  printf '  %-17s %-36s %s\n' "${P_KIND[$i]}" "${P_ID[$i]}" "${P_ACTION[$i]}"
  case "${P_ACTION[$i]}" in delete*) DELETE_COUNT=$((DELETE_COUNT + 1)) ;; esac
  i=$((i + 1))
done

action_of() {
  local j=0
  while [ "$j" -lt "${#P_KIND[@]}" ]; do
    if [ "${P_KIND[$j]}" = "$1" ] && [ "${P_ID[$j]}" = "$2" ]; then
      printf '%s' "${P_ACTION[$j]}"
      return 0
    fi
    j=$((j + 1))
  done
}

# retry N SECONDS CMD...: runs CMD up to N times, SECONDS apart.
retry() {
  local n="$1" s="$2" k=1
  shift 2
  until "$@"; do
    [ "$k" -lt "$n" ] || return 1
    k=$((k + 1))
    sleep "$s"
  done
}

# ---- delete -----------------------------------------------------------------------------------
if [ "$EXECUTE" = 0 ]; then
  echo "Dry run: nothing was deleted. Re-run with --execute to delete the resources marked delete."
elif [ "$DELETE_COUNT" -eq 0 ]; then
  echo "Nothing to delete."
else
  confirm DELETE
  if [ "$EKS_DELETE" = 1 ]; then
    info "Deleting EKS cluster $CLUSTER with eksctl (this takes several minutes)"
    eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait
  fi
  if [ "${#INSTANCES[@]}" -gt 0 ]; then
    info "Terminating ${#INSTANCES[@]} instance(s)"
    aws ec2 terminate-instances --instance-ids "${INSTANCES[@]}" --output json >/dev/null
    aws ec2 wait instance-terminated --instance-ids "${INSTANCES[@]}"
  fi
  aws_lookup ec2 describe-volumes --filters "${FILTERS[@]}" Name=status,Values=available
  for row in $(eks_split '.Volumes[]' VolumeId); do
    [ -z "${row#*=}" ] || continue
    id="${row%%=*}"
    info "Deleting volume $id"
    aws ec2 delete-volume --volume-id "$id"
  done
  i=0
  while [ "$i" -lt "${#P_KIND[@]}" ]; do
    kind="${P_KIND[$i]}"
    id="${P_ID[$i]}"
    if [ "${P_ACTION[$i]}" = delete ]; then
      case "$kind" in
        security-group)
          info "Deleting security group $id"
          retry 10 15 aws ec2 delete-security-group --group-id "$id" ||
            die "could not delete security group $id"
          ;;
        key-pair)
          info "Deleting key pair $id"
          aws ec2 delete-key-pair --key-pair-id "$id"
          ;;
      esac
    fi
    i=$((i + 1))
  done
  if [ "$PROFILE_DELETE" = 1 ]; then
    info "Deleting instance profile $ROLE"
    aws_lookup iam get-instance-profile --instance-profile-name "$ROLE" || AWS_OUT='{"InstanceProfile":{"Roles":[]}}'
    for r in $(ids_of '.InstanceProfile.Roles[].RoleName'); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$r"
    done
    aws iam delete-instance-profile --instance-profile-name "$ROLE"
  fi
  if [ "$ROLE_DELETE" = 1 ]; then
    info "Deleting IAM role $ROLE"
    aws_lookup iam list-attached-role-policies --role-name "$ROLE"
    for arn in $(ids_of '.AttachedPolicies[].PolicyArn'); do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"
    done
    aws_lookup iam list-role-policies --role-name "$ROLE"
    for p in $(ids_of '.PolicyNames[]'); do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p"
    done
    aws iam delete-role --role-name "$ROLE"
  fi
  if [ "$BUCKET_DELETE" = 1 ]; then
    info "Emptying and deleting bucket $BUCKET"
    aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$BUCKET"
  fi
  echo "Deletion finished."
fi

if [ "$VERIFY" = 0 ]; then
  exit 0
fi

# ---- verify -----------------------------------------------------------------------------------
echo "Verification (Region $REGION, run ID $RUN_ID):"
R_KIND=()
R_ID=()
remain() {
  R_KIND+=("$1")
  R_ID+=("$2")
  printf '  remains: %-17s %s\n' "$1" "$2"
}
aws_lookup ec2 describe-instances --filters "${FILTERS[@]}" \
  Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down
for id in $(ids_of '.Reservations[].Instances[].InstanceId'); do remain instance "$id"; done
aws_lookup ec2 describe-volumes --filters "${FILTERS[@]}"
for id in $(ids_of '.Volumes[].VolumeId'); do remain volume "$id"; done
aws_lookup ec2 describe-snapshots --owner-ids self --filters "${FILTERS[@]}"
for id in $(ids_of '.Snapshots[].SnapshotId'); do remain snapshot "$id"; done
aws_lookup ec2 describe-images --owners self --filters "${FILTERS[@]}"
for id in $(ids_of '.Images[].ImageId'); do remain ami "$id"; done
aws_lookup ec2 describe-security-groups --filters "${FILTERS[@]}"
for id in $(ids_of '.SecurityGroups[].GroupId'); do remain security-group "$id"; done
aws_lookup ec2 describe-key-pairs --filters "${FILTERS[@]}"
for id in $(ids_of '.KeyPairs[].KeyPairId'); do remain key-pair "$id"; done
aws_lookup ec2 describe-nat-gateways --filter "${FILTERS[@]}"
for id in $(ids_of '.NatGateways[] | select(.State != "deleted") | .NatGatewayId'); do remain nat-gateway "$id"; done
aws_lookup ec2 describe-addresses --filters "${FILTERS[@]}"
for id in $(ids_of '.Addresses[].AllocationId'); do remain elastic-ip "$id"; done
aws_lookup eks list-clusters
for c in $(ids_of '.clusters[]'); do
  if aws_lookup eks describe-cluster --name "$c" &&
    printf '%s' "$AWS_OUT" | jq -c '.cluster.tags // {}' | has_run_tags "$RUN_ID"; then
    remain eks-cluster "$c"
  fi
done
if [ -n "$CLUSTER" ]; then
  aws_lookup cloudformation list-stacks --stack-status-filter CREATE_IN_PROGRESS CREATE_FAILED \
    CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE DELETE_IN_PROGRESS \
    DELETE_FAILED UPDATE_IN_PROGRESS UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED
  for s in $(ids_of '.StackSummaries[].StackName' | grep "^eksctl-$CLUSTER-" || true); do
    remain cloudformation-stack "$s"
  done
  aws_lookup iam list-roles
  for r in $(ids_of '.Roles[].RoleName' | grep "^eksctl-$CLUSTER-" || true); do remain iam-role "$r"; done
fi
if aws_lookup iam get-role --role-name "$ROLE"; then remain iam-role "$ROLE"; fi
if aws_lookup iam get-instance-profile --instance-profile-name "$ROLE"; then remain instance-profile "$ROLE"; fi
if aws_lookup s3api head-bucket --bucket "$BUCKET"; then remain s3-bucket "$BUCKET"; fi
# Anything else with the run's tags. The tagging API can list deleted EC2 instances, volumes and
# network interfaces for an hour or more; those are checked with describe-* and counted only if
# they still exist (an instance in the state terminated counts as deleted).
STALE_LIST="" # ARNs listed by the tagging API that no longer exist, one per line
# ec2_exists KIND ID: the EC2 resource still exists
ec2_exists() {
  case "$1" in
    instance)
      aws_lookup ec2 describe-instances --instance-ids "$2" || return 1
      [ "$(ids_of '[.Reservations[].Instances[] | select(.State.Name != "terminated")] | length')" != 0 ]
      ;;
    volume) aws_lookup ec2 describe-volumes --volume-ids "$2" ;;
    network-interface) aws_lookup ec2 describe-network-interfaces --network-interface-ids "$2" ;;
  esac
}
aws_lookup resourcegroupstaggingapi get-resources --tag-filters \
  "Key=$SAMPLE_TAG_KEY,Values=$SAMPLE_TAG_VALUE" "Key=$RUN_ID_TAG_KEY,Values=$RUN_ID"
for arn in $(ids_of '.ResourceTagMappingList[].ResourceARN'); do
  known=0
  j=0
  while [ "$j" -lt "${#R_ID[@]}" ]; do
    case "$arn" in *"${R_ID[$j]}"*) known=1 ;; esac
    j=$((j + 1))
  done
  [ "$known" = 0 ] || continue
  case "$arn" in
    arn:aws:ec2:*:instance/* | arn:aws:ec2:*:volume/* | arn:aws:ec2:*:network-interface/*)
      kind="${arn##*:}"
      kind="${kind%%/*}"
      if ec2_exists "$kind" "${arn##*/}"; then
        remain "$kind" "${arn##*/}"
      else
        STALE_LIST="$STALE_LIST$arn"$'\n'
        printf '  listed by the tagging API but already deleted: %s\n' "$arn"
      fi
      ;;
    *) remain tagged-resource "$arn" ;;
  esac
done

echo "remaining: ${#R_KIND[@]}"
if [ -n "$VERIFY_OUT" ]; then
  {
    i=0
    while [ "$i" -lt "${#R_KIND[@]}" ]; do
      jq -cn --arg k "${R_KIND[$i]}" --arg id "${R_ID[$i]}" '{kind: $k, id: $id}'
      i=$((i + 1))
    done
  } | jq -s --arg run "$RUN_ID" --arg region "$REGION" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg stale "$STALE_LIST" \
    '{run_id: $run, region: $region, time: $time, remaining: length, resources: .,
      tagging_api_already_deleted: ($stale | split("\n") | map(select(. != "")))}' >"$VERIFY_OUT"
fi
[ "${#R_KIND[@]}" -eq 0 ] || exit 1
echo "Nothing of run $RUN_ID remains."

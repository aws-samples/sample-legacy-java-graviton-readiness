#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Creates the EC2 test hosts of one lab run: an S3 bucket for bundles and results, an IAM
# role and instance profile for Session Manager and that bucket, a security group without
# inbound rules, and one Amazon Linux 2023 instance per instance type and group. Every
# resource carries the tags project, owner and run-id. Instances terminate themselves when
# they shut down, and a shutdown timer in the user data bounds their lifetime.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --owner OWNER --run-id RUN_ID --types LIST [options]

Creates (billable): S3 bucket $NAME_PREFIX-<run-id>, IAM role and instance profile
$NAME_PREFIX-<run-id>-ec2, security group $NAME_PREFIX-<run-id> in the default VPC, and
one instance per type and group, named $NAME_PREFIX-<run-id>-<label> where <label> is
<type family>-<group>, for example c9g-g1.

Required:
  --region REGION         AWS Region, for example us-east-1
  --owner OWNER           Value of the owner tag (a-z 0-9 . _ -)
  --run-id RUN_ID         Run ID: part of every name and the run-id tag (a-z 0-9 -)
  --types LIST            Comma-separated instance types, for example c9g.2xlarge,c8i.2xlarge

Options:
  --groups LIST           Comma-separated host groups; one instance per type and group
                          (default: g1)
  --volume-gib N          Root volume size in GiB, gp3, encrypted, 20 to 500 (default: 50)
  --max-hours N           Shutdown timer in the user data, 1 to 48 (default: 12); the
                          instance terminates when it shuts down
  --resources-log FILE    Append one JSON line per created resource
  --profile PROFILE       AWS CLI profile (default: the default credential chain)
  --dry-run               Resolve AMIs, VPC and subnet, print the plan, create nothing
  --yes                   Do not ask for confirmation
  -h, --help              Show this help

The instances have no inbound rules and no key pair; use Session Manager (infra/ec2-exec.sh).
Exit codes: 0 success, 1 runtime error, 2 usage error.
EOF
}

REGION="${AWS_REGION:-}"
OWNER=""
RUN_ID=""
TYPES=""
GROUPS_LIST="g1"
VOLUME_GIB=50
MAX_HOURS=12
RESOURCES_LOG=""
PROFILE=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --owner) need_arg "$@"; OWNER="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --types) need_arg "$@"; TYPES="$2"; shift 2 ;;
    --groups) need_arg "$@"; GROUPS_LIST="$2"; shift 2 ;;
    --volume-gib) need_arg "$@"; VOLUME_GIB="$2"; shift 2 ;;
    --max-hours) need_arg "$@"; MAX_HOURS="$2"; shift 2 ;;
    --resources-log) need_arg "$@"; RESOURCES_LOG="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$OWNER" ] || usage_error "--owner is required"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
[ -n "$TYPES" ] || usage_error "--types is required"
validate_region "$REGION"
validate_owner "$OWNER"
validate_run_id "$RUN_ID"
TYPE_LIST="$(split_list "$TYPES")" || exit 2
for t in $TYPE_LIST; do validate_instance_type "$t"; done
GROUP_LIST="$(split_list "$GROUPS_LIST")" || exit 2
for g in $GROUP_LIST; do _matches "$g" '^[a-z0-9]{1,8}$' || usage_error "invalid group '$g'"; done
validate_int --volume-gib "$VOLUME_GIB" 20 500
validate_int --max-hours "$MAX_HOURS" 1 48
if [ -n "$PROFILE" ]; then validate_profile "$PROFILE"; fi

require_cmd aws jq
setup_aws_env "$PROFILE" "$REGION"
init_tmpdir

BUCKET="$(bucket_name "$RUN_ID")"
ROLE="$(role_name "$RUN_ID")"
SG_NAME="$(sg_name "$RUN_ID")"

# ---- resolve the plan (read-only calls) -----------------------------------------------------
show_identity

# Architecture and AMI per instance type (parallel arrays).
T_TYPE=()
T_AMI=()
for t in $TYPE_LIST; do
  aws_lookup ec2 describe-instance-types --instance-types "$t" ||
    die "instance type $t is not available in $REGION"
  arch="$(printf '%s' "$AWS_OUT" | jq -r '.InstanceTypes[0].ProcessorInfo.SupportedArchitectures | if index("arm64") then "arm64" else "x86_64" end')"
  param="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$arch"
  aws_lookup ssm get-parameter --name "$param" || die "SSM parameter $param not found in $REGION"
  T_TYPE+=("$t")
  T_AMI+=("$(printf '%s' "$AWS_OUT" | jq -r '.Parameter.Value')")
done

aws_lookup ec2 describe-vpcs --filters Name=is-default,Values=true || AWS_OUT='{"Vpcs":[]}'
VPC_ID="$(printf '%s' "$AWS_OUT" | jq -r '.Vpcs[0].VpcId // empty')"
[ -n "$VPC_ID" ] || die "no default VPC in $REGION; create one with 'aws ec2 create-default-vpc' or use another Region"

# Availability Zones (by name) that offer every instance type and have a default subnet.
# Instances go to the first one; an instance for which a zone has no capacity
# (InsufficientInstanceCapacity) is created in the next one.
aws_lookup ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=$(printf '%s' "$TYPE_LIST" | tr '\n' ',' | sed 's/,$//')" ||
  die "cannot list instance type offerings"
AZS="$(printf '%s' "$AWS_OUT" | jq -r --argjson n "${#T_TYPE[@]}" '
  [.InstanceTypeOfferings[] | {az: .Location, t: .InstanceType}] | group_by(.az)
  | map(select((map(.t) | unique | length) == $n) | .[0].az) | sort | .[]')"
[ -n "$AZS" ] || die "no Availability Zone in $REGION offers all of: $TYPES"
AZ_NAME=()
AZ_SUBNET=()
for z in $AZS; do
  aws_lookup ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    "Name=availability-zone,Values=$z" Name=default-for-az,Values=true || AWS_OUT='{"Subnets":[]}'
  s="$(printf '%s' "$AWS_OUT" | jq -r '.Subnets[0].SubnetId // empty')"
  if [ -n "$s" ]; then
    AZ_NAME+=("$z")
    AZ_SUBNET+=("$s")
  fi
done
[ "${#AZ_NAME[@]}" -gt 0 ] || die "no default subnet in the Availability Zones that offer all of: $TYPES"

if aws_lookup s3api head-bucket --bucket "$BUCKET"; then
  die "bucket $BUCKET already exists: choose another --run-id"
fi
if aws_lookup iam get-role --role-name "$ROLE"; then
  die "IAM role $ROLE already exists: choose another --run-id"
fi

echo "Plan (Region $REGION, run ID $RUN_ID, owner $OWNER):"
printf '  %-18s %s\n' "S3 bucket" "$BUCKET (Block Public Access, SSE-S3, TLS only)"
printf '  %-18s %s\n' "IAM role/profile" "$ROLE (AmazonSSMManagedInstanceCore + S3 access to $BUCKET only)"
printf '  %-18s %s\n' "Security group" "$SG_NAME in $VPC_ID (no inbound rules)"
printf '  %-18s %s\n' "Subnet" "${AZ_SUBNET[0]} (${AZ_NAME[0]}, default subnet, public IPv4)"
if [ "${#AZ_NAME[@]}" -gt 1 ]; then
  printf '  %-18s %s\n' "Fallback zones" "${AZ_NAME[*]:1} (for a type without capacity in ${AZ_NAME[0]})"
fi
i=0
while [ "$i" -lt "${#T_TYPE[@]}" ]; do
  for g in $GROUP_LIST; do
    printf '  %-18s %s %s, %s GiB gp3, shutdown after %s h\n' "Instance" "${T_TYPE[$i]}" \
      "${T_AMI[$i]}" "$VOLUME_GIB" "$MAX_HOURS"
  done
  i=$((i + 1))
done
printf '  %-18s %s=%s, %s=%s, %s=%s\n' "Tags" "$SAMPLE_TAG_KEY" "$SAMPLE_TAG_VALUE" \
  "$OWNER_TAG_KEY" "$OWNER" "$RUN_ID_TAG_KEY" "$RUN_ID"
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing was created."
  exit 0
fi
echo "This creates billable resources (EC2 instances, EBS volumes, public IPv4 addresses, S3)."
confirm yes

# ---- create ---------------------------------------------------------------------------------
TAGS="$(tags_shorthand "$OWNER" "$RUN_ID")"
IAM_TAGS=("Key=$SAMPLE_TAG_KEY,Value=$SAMPLE_TAG_VALUE" "Key=$OWNER_TAG_KEY,Value=$OWNER"
  "Key=$RUN_ID_TAG_KEY,Value=$RUN_ID")

info "Creating bucket $BUCKET"
if [ "$REGION" = us-east-1 ]; then
  aws s3api create-bucket --bucket "$BUCKET" --output json >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" --output json >/dev/null
fi
log_resource "$RESOURCES_LOG" s3-bucket "$BUCKET" "$OWNER" "$RUN_ID"
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[$TAGS]"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
jq -n --arg b "$BUCKET" '{Version: "2012-10-17", Statement: [{Sid: "DenyInsecureTransport",
  Effect: "Deny", Principal: "*", Action: "s3:*",
  Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
  Condition: {Bool: {"aws:SecureTransport": "false"}}}]}' >"$TMP_WORK/bucket-policy.json"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$TMP_WORK/bucket-policy.json"

info "Creating IAM role and instance profile $ROLE"
jq -n '{Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Service: "ec2.amazonaws.com"}, Action: "sts:AssumeRole"}]}' >"$TMP_WORK/trust.json"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$TMP_WORK/trust.json" \
  --description "Lab hosts of $SAMPLE_TAG_VALUE run $RUN_ID" --tags "${IAM_TAGS[@]}" --output json >/dev/null
log_resource "$RESOURCES_LOG" iam-role "$ROLE" "$OWNER" "$RUN_ID"
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
jq -n --arg b "$BUCKET" '{Version: "2012-10-17", Statement: [
  {Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject"], Resource: "arn:aws:s3:::\($b)/*"},
  {Effect: "Allow", Action: "s3:ListBucket", Resource: "arn:aws:s3:::\($b)"}]}' >"$TMP_WORK/s3-policy.json"
aws iam put-role-policy --role-name "$ROLE" --policy-name lab-bucket-access \
  --policy-document "file://$TMP_WORK/s3-policy.json"
aws iam create-instance-profile --instance-profile-name "$ROLE" --tags "${IAM_TAGS[@]}" --output json >/dev/null
log_resource "$RESOURCES_LOG" iam-instance-profile "$ROLE" "$OWNER" "$RUN_ID"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
aws iam wait instance-profile-exists --instance-profile-name "$ROLE"

info "Creating security group $SG_NAME"
SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
  --description "Lab hosts of run $RUN_ID, no inbound rules" \
  --tag-specifications "ResourceType=security-group,Tags=[$TAGS]" --output json | jq -r '.GroupId')"
log_resource "$RESOURCES_LOG" security-group "$SG_ID" "$OWNER" "$RUN_ID"

cat >"$TMP_WORK/user-data.sh" <<EOF
#!/bin/bash
# Lab host of run $RUN_ID: terminate after $MAX_HOURS hours at the latest.
set -euo pipefail
shutdown -h +$((MAX_HOURS * 60))
dnf install -y docker binutils jq tar gzip
systemctl enable --now docker
EOF

echo "Instances:"
i=0
while [ "$i" -lt "${#T_TYPE[@]}" ]; do
  t="${T_TYPE[$i]}"
  for g in $GROUP_LIST; do
    label="${t%%.*}-$g"
    name="$NAME_PREFIX-$RUN_ID-$label"
    itags="$(tags_shorthand "$OWNER" "$RUN_ID" "$name"),{Key=lab-host,Value=$label}"
    placed=""
    k=0
    while [ -z "$placed" ] && [ "$k" -lt "${#AZ_NAME[@]}" ]; do
      attempt=1
      while :; do
        rc=0
        out="$(aws ec2 run-instances --image-id "${T_AMI[$i]}" --instance-type "$t" \
          --subnet-id "${AZ_SUBNET[$k]}" --security-group-ids "$SG_ID" \
          --iam-instance-profile "Name=$ROLE" --instance-initiated-shutdown-behavior terminate \
          --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
          --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$VOLUME_GIB,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
          --tag-specifications "ResourceType=instance,Tags=[$itags]" "ResourceType=volume,Tags=[$TAGS]" \
          --user-data "file://$TMP_WORK/user-data.sh" --count 1 --output json 2>"$TMP_WORK/run-err")" || rc=$?
        if [ "$rc" = 0 ]; then
          placed="${AZ_NAME[$k]}"
          break
        fi
        cat "$TMP_WORK/run-err" >&2
        if grep -q InsufficientInstanceCapacity "$TMP_WORK/run-err"; then
          warn "no $t capacity in ${AZ_NAME[$k]}"
          break
        fi
        # A new instance profile can take a few seconds to become usable by EC2.
        [ "$attempt" -lt 6 ] ||
          die "run-instances failed for $t ($g); delete what was created with infra/cleanup.sh --region $REGION --run-id $RUN_ID --execute"
        attempt=$((attempt + 1))
        sleep 10
      done
      k=$((k + 1))
    done
    [ -n "$placed" ] ||
      die "no capacity for $t ($g) in ${AZ_NAME[*]}; delete what was created with infra/cleanup.sh --region $REGION --run-id $RUN_ID --execute"
    id="$(printf '%s' "$out" | jq -r '.Instances[0].InstanceId')"
    log_resource "$RESOURCES_LOG" ec2-instance "$id" "$OWNER" "$RUN_ID"
    printf '  %-12s %-14s %s %s\n' "$label" "$t" "$id" "$placed"
  done
  i=$((i + 1))
done
echo "Next: infra/ec2-exec.sh --region $REGION --run-id $RUN_ID --instance-id <id> --bundle DIR --script NAME"
echo "Cleanup: infra/cleanup.sh --region $REGION --run-id $RUN_ID"

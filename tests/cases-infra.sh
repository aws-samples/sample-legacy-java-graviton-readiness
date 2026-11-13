#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Test cases for infra/ (EC2 hosts, Run Command, result collection, cleanup). Sourced by
# tests/run-tests.sh.
# shellcheck disable=SC2034  # STUB_ENV is read by run_script in tests/run-tests.sh

# shellcheck disable=SC2054  # the comma separates instance types inside one value
UP=(--region us-east-1 --owner example-owner --run-id test-run-1 --types c8g.2xlarge,c9g.2xlarge)
TAGS_EXPECTED="{Key=project,Value=sample-legacy-java-graviton-readiness},{Key=owner,Value=example-owner},{Key=run-id,Value=test-run-1}"

# ---- infra/ec2-up.sh --------------------------------------------------------------------------
test_ec2_up_dry_run() {
  run_script infra/ec2-up.sh "${UP[@]}" --groups g1,g2 --dry-run
  assert_exit 0
  assert_contains "S3 bucket          legacy-java-graviton-test-run-1"
  assert_contains "IAM role/profile   legacy-java-graviton-test-run-1-ec2"
  assert_contains "subnet-0123456789abcdef0 (us-east-1b, default subnet, public IPv4)"
  [ "$(grep -c '^  Instance ' "$OUT")" = 4 ] || fail "expected 4 instances in the plan"
  assert_contains "Dry run: nothing was created."
  assert_called "aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
  assert_not_called "create-"
  assert_not_called "run-instances"
  assert_not_called "put-"
}

test_ec2_up_create() {
  run_script infra/ec2-up.sh "${UP[@]}" --yes --resources-log "$CASE_DIR/resources.jsonl" --max-hours 6
  assert_exit 0
  assert_order "aws s3api create-bucket --bucket legacy-java-graviton-test-run-1" "aws iam create-role"
  assert_order "aws iam create-role" "aws iam create-instance-profile"
  assert_order "aws iam create-instance-profile" "aws ec2 create-security-group"
  assert_order "aws ec2 create-security-group" "aws ec2 run-instances"
  assert_called "aws s3api put-public-access-block --bucket legacy-java-graviton-test-run-1 --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  assert_called "aws s3api put-bucket-encryption"
  assert_called "aws s3api put-bucket-policy"
  assert_called "aws s3api put-bucket-tagging --bucket legacy-java-graviton-test-run-1 --tagging TagSet=[$TAGS_EXPECTED]"
  assert_called "--tags Key=project,Value=sample-legacy-java-graviton-readiness Key=owner,Value=example-owner Key=run-id,Value=test-run-1"
  assert_called "--policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  assert_called "--tag-specifications ResourceType=security-group,Tags=[$TAGS_EXPECTED]"
  assert_called "--instance-initiated-shutdown-behavior terminate"
  assert_called "--metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1"
  assert_called "Ebs={VolumeSize=50,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}"
  assert_called "ResourceType=instance,Tags=[$TAGS_EXPECTED,{Key=Name,Value=legacy-java-graviton-test-run-1-c8g-g1},{Key=lab-host,Value=c8g-g1}]"
  assert_called "ResourceType=volume,Tags=[$TAGS_EXPECTED]"
  assert_not_called "authorize-security-group-ingress"
  assert_not_called "create-key-pair"
  [ "$(grep -c 'ec2 run-instances' "$STUB_LOG")" = 2 ] || fail "expected 2 run-instances calls"
  assert_contains "c8g-g1       c8g.2xlarge    i-0123456789abcdef0"
  [ "$(wc -l <"$CASE_DIR/resources.jsonl" | tr -d ' ')" = 6 ] || fail "expected 6 resource log lines"
  jq -e -s 'all(.tags.project == "sample-legacy-java-graviton-readiness" and .tags["run-id"] == "test-run-1" and .tags.owner == "example-owner")' \
    "$CASE_DIR/resources.jsonl" >/dev/null || fail "resource log lines without tags"
}

test_ec2_up_capacity_fallback() {
  # c9g is offered in us-east-1a and us-east-1b; us-east-1a has no capacity.
  stub_env STUB_ICE_SUBNET=subnet-0abcdef1234567890
  run_script infra/ec2-up.sh --region us-east-1 --owner example-owner --run-id test-run-1 \
    --types c9g.2xlarge --yes
  assert_exit 0
  assert_contains "Fallback zones     us-east-1b (for a type without capacity in us-east-1a)"
  assert_contains "no c9g.2xlarge capacity in us-east-1a"
  assert_order "--subnet-id subnet-0abcdef1234567890" "--subnet-id subnet-0123456789abcdef0"
  [ "$(grep -c 'ec2 run-instances' "$STUB_LOG")" = 2 ] || fail "expected 2 run-instances calls"
  assert_contains "c9g-g1       c9g.2xlarge    i-0123456789abcdef0 us-east-1b"
}
test_ec2_up_refuses() {
  stub_env STUB_WORLD=present
  run_script infra/ec2-up.sh "${UP[@]}" --yes
  assert_exit 1
  assert_contains "already exists: choose another --run-id"
  STUB_ENV=(STUB_NO_DEFAULT_VPC=1)
  run_script infra/ec2-up.sh "${UP[@]}" --yes
  assert_exit 1
  assert_contains "no default VPC"
  STUB_ENV=()
  run_script infra/ec2-up.sh "${UP[@]}"
  assert_exit 1
  assert_contains "stdin is not a terminal"
  assert_not_called "create-"
  run_script infra/ec2-up.sh --region us-east-1 --run-id test-run-1 --types c8g.2xlarge
  assert_exit 2
  assert_contains "--owner is required"
  run_script infra/ec2-up.sh "${UP[@]}" --run-id Bad_Run
  assert_exit 2
  run_script infra/ec2-up.sh "${UP[@]}" --max-hours 49 --dry-run
  assert_exit 2
}

# ---- infra/ec2-exec.sh ------------------------------------------------------------------------
test_ec2_exec() {
  mkdir -p "$CASE_DIR/bundle"
  printf '#!/bin/bash\necho run\n' >"$CASE_DIR/bundle/run.sh"
  stub_env STUB_WORLD=present
  run_script infra/ec2-exec.sh --region us-east-1 --run-id test-run-1 --instance-id i-0123456789abcdef0 \
    --bundle "$CASE_DIR/bundle" --script run.sh
  assert_exit 0
  assert_contains "Command ID: 11111111-2222-3333-4444-5555aaaabbbb"
  assert_called "aws s3 cp"
  assert_called "s3://legacy-java-graviton-test-run-1/bundles/i-0123456789abcdef0/bundle-"
  assert_called "aws ssm send-command --instance-ids i-0123456789abcdef0 --document-name AWS-RunShellScript"
  jq -e '.commands | map(select(test("systemd-run --unit jvmlab-") and test("JVMLAB_RESULTS=s3://legacy-java-graviton-test-run-1/results/c8g-g1/"))) | length == 1' \
    "$CASE_DIR/ssm-params.json" >/dev/null || fail "Run Command parameters: $(cat "$CASE_DIR/ssm-params.json")"
}

test_ec2_exec_refuses() {
  mkdir -p "$CASE_DIR/bundle"
  printf '#!/bin/bash\n' >"$CASE_DIR/bundle/run.sh"
  stub_env STUB_WORLD=untagged
  run_script infra/ec2-exec.sh --region us-east-1 --run-id test-run-1 --instance-id i-0123456789abcdef0 \
    --bundle "$CASE_DIR/bundle" --script run.sh
  assert_exit 1
  assert_contains "does not carry the tags"
  STUB_ENV=(STUB_WORLD=present STUB_INSTANCE_STATE=stopped)
  run_script infra/ec2-exec.sh --region us-east-1 --run-id test-run-1 --instance-id i-0123456789abcdef0 \
    --bundle "$CASE_DIR/bundle" --script run.sh
  assert_exit 1
  assert_contains "is stopped, not running"
  run_script infra/ec2-exec.sh --region us-east-1 --run-id test-run-1 --instance-id i-0123456789abcdef0 \
    --bundle "$CASE_DIR/bundle" --script ../run.sh
  assert_exit 2
  run_script infra/ec2-exec.sh --region us-east-1 --run-id test-run-1 --instance-id i-0123456789abcdef0 \
    --bundle "$CASE_DIR/bundle" --script missing.sh
  assert_exit 1
  assert_not_called "send-command"
}

# ---- infra/collect.sh -------------------------------------------------------------------------
test_collect() {
  stub_env STUB_WORLD=present
  run_script infra/collect.sh --region us-east-1 --run-id test-run-1 --dest "$CASE_DIR/raw"
  assert_exit 0
  assert_called "aws s3 sync s3://legacy-java-graviton-test-run-1/results/ $CASE_DIR/raw/ --only-show-errors"
  STUB_ENV=(STUB_WORLD=untagged)
  : >"$STUB_LOG"
  run_script infra/collect.sh --region us-east-1 --run-id test-run-1 --dest "$CASE_DIR/raw"
  assert_exit 1
  assert_not_called "s3 sync"
}

# ---- infra/cleanup.sh -------------------------------------------------------------------------
test_cleanup_dry_run() {
  stub_env STUB_WORLD=present
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1
  assert_exit 0
  assert_contains "instance          i-0123456789abcdef0                  delete"
  assert_contains "volume            vol-0123456789abcdef0                delete after its instance terminates"
  assert_contains "security-group    sg-0123456789abcdef0                 delete"
  assert_contains "instance-profile  legacy-java-graviton-test-run-1-ec2  delete"
  assert_contains "iam-role          legacy-java-graviton-test-run-1-ec2  delete"
  assert_contains "s3-bucket         legacy-java-graviton-test-run-1      delete"
  assert_contains "Dry run: nothing was deleted."
  assert_not_called "terminate-"
  assert_not_called "delete-"
  assert_not_called "s3 rm"
}

test_cleanup_execute_and_verify() {
  stub_env STUB_WORLD=present
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --eks-cluster jvm-cgroup-test-run-1 \
    --execute --yes --verify --verify-out "$CASE_DIR/verify.json"
  assert_exit 0
  assert_order "eksctl delete cluster --name jvm-cgroup-test-run-1" "aws ec2 terminate-instances --instance-ids i-0123456789abcdef0"
  assert_order "aws ec2 terminate-instances" "aws ec2 wait instance-terminated"
  assert_order "aws ec2 wait instance-terminated" "aws ec2 delete-security-group --group-id sg-0123456789abcdef0"
  assert_order "aws iam remove-role-from-instance-profile" "aws iam delete-instance-profile"
  assert_order "aws iam detach-role-policy" "aws iam delete-role --role-name legacy-java-graviton-test-run-1-ec2"
  assert_order "aws iam delete-role-policy" "aws iam delete-role "
  assert_order "aws s3 rm s3://legacy-java-graviton-test-run-1 --recursive" "aws s3api delete-bucket"
  assert_contains "remaining: 0"
  assert_contains "Nothing of run test-run-1 remains."
  jq -e '.remaining == 0 and .run_id == "test-run-1"' "$CASE_DIR/verify.json" >/dev/null || fail "verify.json: $(cat "$CASE_DIR/verify.json")"
}

test_cleanup_verify_reports_remaining() {
  stub_env STUB_WORLD=present
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --eks-cluster jvm-cgroup-test-run-1 --verify
  assert_exit 1
  assert_contains "remains: instance          i-0123456789abcdef0"
  assert_contains "remains: security-group    sg-0123456789abcdef0"
  assert_contains "remains: eks-cluster       jvm-cgroup-test-run-1"
  assert_contains "remains: cloudformation-stack eksctl-jvm-cgroup-test-run-1-cluster"
  assert_contains "remains: s3-bucket         legacy-java-graviton-test-run-1"
  assert_not_contains "tagged-resource"
  assert_not_called "delete-"
}

test_cleanup_verify_tagging_lag() {
  # the tagging API still lists a terminated instance, a deleted volume and a deleted ENI
  stub_env STUB_TAG_LAG=deleted
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --verify --verify-out "$CASE_DIR/verify.json"
  assert_exit 0
  local a="arn:aws:ec2:us-east-1:123456789012"
  assert_contains "listed by the tagging API but already deleted: $a:instance/i-0abcdef1234567890"
  assert_contains "listed by the tagging API but already deleted: $a:volume/vol-0abcdef1234567890"
  assert_contains "listed by the tagging API but already deleted: $a:network-interface/eni-0abcdef1234567890"
  assert_contains "remaining: 0"
  assert_called "aws ec2 describe-network-interfaces --network-interface-ids eni-0abcdef1234567890"
  jq -e '.remaining == 0 and (.tagging_api_already_deleted | length) == 3' "$CASE_DIR/verify.json" >/dev/null ||
    fail "verify.json: $(cat "$CASE_DIR/verify.json")"
  # an ENI that still exists counts as remaining
  stub_env STUB_TAG_LAG=eni-exists
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --verify
  assert_exit 1
  assert_contains "remains: network-interface eni-0abcdef1234567890"
  assert_contains "remaining: 1"
}
test_cleanup_skips_untagged() {
  stub_env STUB_WORLD=untagged
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --eks-cluster jvm-cgroup-test-run-1 --execute --yes
  assert_exit 0
  assert_contains "eks-cluster       jvm-cgroup-test-run-1                skip (not tagged for run test-run-1)"
  assert_contains "iam-role          legacy-java-graviton-test-run-1-ec2  skip (not tagged for run test-run-1)"
  assert_contains "s3-bucket         legacy-java-graviton-test-run-1      skip (not tagged for run test-run-1)"
  assert_contains "Nothing to delete."
  assert_not_called "delete-"
  assert_not_called "terminate-"
  assert_not_called "eksctl delete"
}

test_cleanup_keeps_eks_parts() {
  stub_env STUB_WORLD=present STUB_EKS_PARTS=1
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --execute --yes
  assert_exit 0
  assert_contains "instance          i-0abcdef1234567890                  skip (part of EKS cluster jvm-cgroup-test-run-1"
  assert_contains "volume            vol-0abcdef1234567890                skip (part of EKS cluster jvm-cgroup-test-run-1"
  assert_contains "security-group    sg-0abcdef1234567890                 skip (part of EKS cluster jvm-cgroup-test-run-1"
  assert_called "aws ec2 terminate-instances --instance-ids i-0123456789abcdef0 --output json"
  assert_called "aws ec2 delete-security-group --group-id sg-0123456789abcdef0"
  assert_not_called "i-0abcdef1234567890"
  assert_not_called "sg-0abcdef1234567890"
  assert_not_called "vol-0abcdef1234567890"
}
test_cleanup_confirmation() {
  stub_env STUB_WORLD=present
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --execute
  assert_exit 1
  assert_contains "stdin is not a terminal"
  assert_not_called "terminate-"
  run_script infra/cleanup.sh --region us-east-1 --run-id test-run-1 --verify-out x.json
  assert_exit 2
}

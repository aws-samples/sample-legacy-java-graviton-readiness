#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Starts a script on one lab instance through AWS Systems Manager Run Command: uploads a
# bundle directory to the run's S3 bucket, and the instance downloads it and runs the script
# as a transient systemd unit, so the script keeps running after the Run Command ends. The
# script finds the result location in the environment variable JVMLAB_RESULTS.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --run-id RUN_ID --instance-id ID --bundle DIR --script NAME
                    [--profile PROFILE]

Packs DIR, uploads it to s3://$NAME_PREFIX-<run-id>/bundles/<instance-id>/, and sends an
AWS-RunShellScript command that extracts it under /opt/jvmlab/<timestamp>/ on the instance and
starts "bash NAME" there with systemd-run. Environment of the script:
  JVMLAB_RESULTS    s3://$NAME_PREFIX-<run-id>/results/<lab-host label>/
  JVMLAB_REGION     the Region
  JVMLAB_HOST_LABEL the lab-host tag of the instance, for example c8g-g1

Options:
  --region REGION     AWS Region
  --run-id RUN_ID     Run ID used with infra/ec2-up.sh
  --instance-id ID    Instance created by infra/ec2-up.sh for this run (tags are checked)
  --bundle DIR        Directory to upload (for example this repository plus your run script)
  --script NAME       Script inside DIR to run, relative path ending in .sh
  --profile PROFILE   AWS CLI profile
  -h, --help          Show this help

Prints the Run Command ID. Follow the unit with:
  aws ssm get-command-invocation --command-id <id> --instance-id <instance-id>
Exit codes: 0 command sent, 1 runtime error, 2 usage error.
EOF
}

REGION="${AWS_REGION:-}"
RUN_ID=""
INSTANCE_ID=""
BUNDLE=""
SCRIPT=""
PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --instance-id) need_arg "$@"; INSTANCE_ID="$2"; shift 2 ;;
    --bundle) need_arg "$@"; BUNDLE="$2"; shift 2 ;;
    --script) need_arg "$@"; SCRIPT="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
[ -n "$INSTANCE_ID" ] || usage_error "--instance-id is required"
[ -n "$BUNDLE" ] || usage_error "--bundle is required"
[ -n "$SCRIPT" ] || usage_error "--script is required"
validate_region "$REGION"
validate_run_id "$RUN_ID"
validate_instance_id "$INSTANCE_ID"
_matches "$SCRIPT" '^[A-Za-z0-9_][A-Za-z0-9._/-]*\.sh$' || usage_error "invalid --script '$SCRIPT'"
case "/$SCRIPT/" in
  */../*) usage_error "--script must not contain .." ;;
esac
if [ -n "$PROFILE" ]; then validate_profile "$PROFILE"; fi
[ -d "$BUNDLE" ] || die "--bundle $BUNDLE is not a directory"
[ -f "$BUNDLE/$SCRIPT" ] || die "$SCRIPT not found in $BUNDLE"

require_cmd aws jq tar
setup_aws_env "$PROFILE" "$REGION"
init_tmpdir
BUCKET="$(bucket_name "$RUN_ID")"

aws_lookup ec2 describe-instances --instance-ids "$INSTANCE_ID" || die "instance $INSTANCE_ID not found"
INST="$(printf '%s' "$AWS_OUT" | jq -c '.Reservations[0].Instances[0]')"
printf '%s' "$INST" | jq -c '.Tags // []' | has_run_tags "$RUN_ID" ||
  die "instance $INSTANCE_ID does not carry the tags $SAMPLE_TAG_KEY=$SAMPLE_TAG_VALUE and $RUN_ID_TAG_KEY=$RUN_ID"
STATE="$(printf '%s' "$INST" | jq -r '.State.Name')"
[ "$STATE" = running ] || die "instance $INSTANCE_ID is $STATE, not running"
LABEL="$(printf '%s' "$INST" | jq -c '.Tags // []' | tag_value lab-host)"
validate_host_label "$LABEL"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
KEY="bundles/$INSTANCE_ID/bundle-$STAMP.tgz"
# On macOS, bsdtar adds extended attributes and AppleDouble files, which GNU tar on the instance
# reports as unknown header keywords; leave them out.
TAR_FLAGS=()
if [ "$(uname -s)" = Darwin ]; then TAR_FLAGS=(--no-xattrs --no-mac-metadata); fi
COPYFILE_DISABLE=1 tar ${TAR_FLAGS[@]+"${TAR_FLAGS[@]}"} -czf "$TMP_WORK/bundle.tgz" -C "$BUNDLE" .
aws s3 cp "$TMP_WORK/bundle.tgz" "s3://$BUCKET/$KEY" --only-show-errors

DIR="/opt/jvmlab/$STAMP"
jq -n --arg dir "$DIR" --arg src "s3://$BUCKET/$KEY" --arg region "$REGION" --arg script "$SCRIPT" \
  --arg results "s3://$BUCKET/results/$LABEL/" --arg label "$LABEL" --arg unit "jvmlab-$STAMP" '{
  commands: [
    "set -euo pipefail",
    "mkdir -p \($dir)",
    "aws s3 cp \($src) \($dir)/bundle.tgz --region \($region) --only-show-errors",
    "tar -xzf \($dir)/bundle.tgz -C \($dir)",
    "systemd-run --unit \($unit) --working-directory=\($dir) --setenv=JVMLAB_RESULTS=\($results) --setenv=JVMLAB_REGION=\($region) --setenv=JVMLAB_HOST_LABEL=\($label) /bin/bash \($dir)/\($script)",
    "echo started unit \($unit)"
  ],
  executionTimeout: ["600"]}' >"$TMP_WORK/params.json"

CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --comment "lab run $RUN_ID $LABEL" --parameters "file://$TMP_WORK/params.json" \
  --output json | jq -r '.Command.CommandId')"
echo "Command ID: $CMD_ID"
echo "Unit on the instance: jvmlab-$STAMP (journalctl -u jvmlab-$STAMP through Session Manager)"
echo "Results: s3://$BUCKET/results/$LABEL/"

#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Downloads the results of one lab run from its S3 bucket (results/ prefix) to a local
# directory. Read-only on the AWS side.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --region REGION --run-id RUN_ID --dest DIR [--profile PROFILE]

Runs "aws s3 sync s3://$NAME_PREFIX-<run-id>/results/ DIR" after checking that the bucket
carries the tags $SAMPLE_TAG_KEY=$SAMPLE_TAG_VALUE and $RUN_ID_TAG_KEY=<run-id>.

Exit codes: 0 success, 1 runtime error, 2 usage error.
EOF
}

REGION="${AWS_REGION:-}"
RUN_ID=""
DEST=""
PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) need_arg "$@"; REGION="$2"; shift 2 ;;
    --run-id) need_arg "$@"; RUN_ID="$2"; shift 2 ;;
    --dest) need_arg "$@"; DEST="$2"; shift 2 ;;
    --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_error "--region is required (or set AWS_REGION)"
[ -n "$RUN_ID" ] || usage_error "--run-id is required"
[ -n "$DEST" ] || usage_error "--dest is required"
validate_region "$REGION"
validate_run_id "$RUN_ID"
if [ -n "$PROFILE" ]; then validate_profile "$PROFILE"; fi

require_cmd aws jq
setup_aws_env "$PROFILE" "$REGION"
init_tmpdir
BUCKET="$(bucket_name "$RUN_ID")"

aws_lookup s3api get-bucket-tagging --bucket "$BUCKET" || die "bucket $BUCKET not found or not tagged"
printf '%s' "$AWS_OUT" | jq -c '.TagSet' | has_run_tags "$RUN_ID" ||
  die "bucket $BUCKET does not carry the tags of run $RUN_ID"
mkdir -p "$DEST"
aws s3 sync "s3://$BUCKET/results/" "$DEST/" --only-show-errors
echo "Results in $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files)"

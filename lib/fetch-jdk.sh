#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Downloads one JDK build from the catalog lib/jdks.csv, verifies its SHA-256 before it is
# extracted, and extracts it into DEST/<jdk-id>. A build that is already present with the
# same checksum is kept; a different build in the same directory is never overwritten.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --list
       $SCRIPT_NAME --id JDK_ID --dest DIR [--arch aarch64|x64|auto] [--cache DIR]
                    [--log FILE] [--host-label LABEL]

Downloads a JDK tarball listed in the catalog, checks its SHA-256 against the catalog, and
extracts it into DIR/JDK_ID (the top-level directory of the tarball is removed).

Options:
  --list              Print the catalog (one row per JDK ID and architecture) and exit
  --id JDK_ID         Catalog ID, for example corretto-8.372.07.1
  --arch ARCH         aarch64, x64, or auto (this machine's architecture; default)
  --dest DIR          Directory that receives DIR/JDK_ID
  --cache DIR         Keep downloaded tarballs here and reuse them when the checksum matches
  --log FILE          Append one CSV line (host,jdk_id,arch,url,alg,expected,actual,ok)
  --host-label LABEL  Host column of the log line (default: the short host name)
  -h, --help          Show this help

Environment:
  JDK_CATALOG         Catalog file (default: lib/jdks.csv next to this script)

Exit codes: 0 success or already present, 1 runtime error (download, checksum, extraction),
2 usage error.
EOF
}

LIST=0
ID=""
ARCH="auto"
DEST=""
CACHE=""
LOG=""
HOST_LABEL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --id) need_arg "$@"; ID="$2"; shift 2 ;;
    --arch) need_arg "$@"; ARCH="$2"; shift 2 ;;
    --dest) need_arg "$@"; DEST="$2"; shift 2 ;;
    --cache) need_arg "$@"; CACHE="$2"; shift 2 ;;
    --log) need_arg "$@"; LOG="$2"; shift 2 ;;
    --host-label) need_arg "$@"; HOST_LABEL="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -r "$JDK_CATALOG" ] || die "catalog not found: $JDK_CATALOG"

if [ "$LIST" = 1 ]; then
  catalog_rows | awk -F, '{ printf "%-24s %-8s %s\n", $1, $5, $6 }'
  exit 0
fi

[ -n "$ID" ] || usage_error "--id is required"
[ -n "$DEST" ] || usage_error "--dest is required"
validate_jdk_id "$ID"
if [ "$ARCH" = auto ]; then ARCH="$(host_jdk_arch)"; fi
validate_jdk_arch "$ARCH"
if [ -n "$HOST_LABEL" ]; then
  validate_host_label "$HOST_LABEL"
else
  HOST_LABEL="$(hostname -s 2>/dev/null || printf 'unknown')"
fi

# awk reads all of its input: an early exit would make catalog_rows fail with SIGPIPE (exit 141
# under pipefail, which stops the script without a message).
ROW="$(catalog_rows | awk -F, -v id="$ID" -v arch="$ARCH" '!done && $1 == id && $5 == arch { print; done = 1 }')"
[ -n "$ROW" ] || die "no catalog entry for $ID ($ARCH); run $SCRIPT_NAME --list"
URL="$(printf '%s' "$ROW" | cut -d, -f6)"
SHA="$(printf '%s' "$ROW" | cut -d, -f7)"
_matches "$SHA" '^[0-9a-f]{64}$' || die "catalog entry for $ID ($ARCH) has no valid SHA-256"
case "$URL" in
  https://*) PROTO="=https" ;;
  file://*)
    # Only the offline tests use local files.
    [ "${FETCH_JDK_ALLOW_FILE:-0}" = 1 ] || die "file:// URLs are allowed only with FETCH_JDK_ALLOW_FILE=1"
    PROTO="=file"
    ;;
  *) die "catalog URL for $ID must use https: $URL" ;;
esac

require_cmd curl tar awk
init_tmpdir
if [ -n "$LOG" ]; then mkdir -p "$(dirname "$LOG")"; fi

log_line() { # log_line ACTUAL OK
  [ -n "$LOG" ] || return 0
  printf '%s,%s,%s,%s,sha256,%s,%s,%s\n' "$HOST_LABEL" "$ID" "$ARCH" "$URL" "$SHA" "$1" "$2" >>"$LOG"
}

TARGET="$DEST/$ID"
MARKER="$TARGET/.fetch-jdk-sha256"
if [ -e "$TARGET" ]; then
  if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$SHA" ] && [ -x "$TARGET/bin/java" ]; then
    info "$ID ($ARCH) already present in $TARGET"
    log_line "$SHA" present
    exit 0
  fi
  die "$TARGET exists but is not the catalog build $ID ($ARCH); remove it yourself to replace it"
fi

mkdir -p "$DEST"
TARBALL=""
if [ -n "$CACHE" ]; then
  mkdir -p "$CACHE"
  TARBALL="$CACHE/$(basename "$URL")"
  if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" != "$SHA" ]; then
    warn "cached $TARBALL has a different checksum; downloading again"
    rm -f -- "$TARBALL"
  fi
fi
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
  PART="$TMP_WORK/download"
  info "Downloading $URL"
  attempt=1
  until curl --fail --silent --show-error --location --proto "$PROTO" --proto-redir "$PROTO" \
    --retry 3 --connect-timeout 30 -o "$PART" "$URL"; do
    [ "$attempt" -lt 3 ] || { log_line "" download-failed; die "download failed: $URL"; }
    attempt=$((attempt + 1))
    sleep 5
  done
  if [ -n "$TARBALL" ]; then
    mv -f -- "$PART" "$TARBALL"
  else
    TARBALL="$PART"
  fi
fi

ACTUAL="$(sha256_of "$TARBALL")"
if [ "$ACTUAL" != "$SHA" ]; then
  log_line "$ACTUAL" checksum-mismatch
  if [ -n "$CACHE" ]; then rm -f -- "$TARBALL"; fi
  die "SHA-256 mismatch for $ID ($ARCH): expected $SHA, got $ACTUAL"
fi

# Refuse tarballs with absolute member paths or .. components before extracting anything.
MEMBERS="$TMP_WORK/members"
tar -tzf "$TARBALL" >"$MEMBERS" || die "cannot list $TARBALL"
if grep -Eq '^/|(^|/)\.\.(/|$)' "$MEMBERS"; then
  die "$TARBALL contains absolute or .. member paths; not extracted"
fi
TOP="$(awk -F/ 'NF { print $1 }' "$MEMBERS" | LC_ALL=C sort -u)"
[ "$(printf '%s\n' "$TOP" | wc -l | tr -d ' ')" = 1 ] || die "$TARBALL does not have one top-level directory"

STAGE="$(mktemp -d "$DEST/.fetch-$ID.XXXXXX")"
if ! tar -xzf "$TARBALL" -C "$STAGE" --strip-components 1 --no-same-owner; then
  rm -rf -- "$STAGE"
  die "cannot extract $TARBALL"
fi
[ -x "$STAGE/bin/java" ] || { rm -rf -- "$STAGE"; die "$TARBALL has no bin/java"; }
printf '%s' "$SHA" >"$STAGE/.fetch-jdk-sha256"
chmod 755 "$STAGE"
mv -- "$STAGE" "$TARGET"
log_line "$ACTUAL" ok
info "$ID ($ARCH) extracted to $TARGET"

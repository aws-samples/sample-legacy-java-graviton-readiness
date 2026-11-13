#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Turns the PrintFlagsFinal files written by run-matrix.sh into a long CSV
# (host,jdk_id,flag,value,origin,present) and a Markdown matrix with one table per host.
# Understands the JDK 8 format ("type name = value {kind}", ":=" for a changed value) and
# the JDK 9+ format ("type name = value {kind} {origin}").
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --in DIR --out-csv FILE --out-md FILE [--flags FILE] [--file NAME]

Reads DIR/<host>/<jdk-id>/NAME for every host and JDK directory under DIR.

Options:
  --in DIR        Result directory of run-matrix.sh (the --out value)
  --flags FILE    Flags to report, one per line, # comments allowed
                  (default: flags.txt next to this script)
  --file NAME     PrintFlagsFinal file to read (default: printflagsfinal-diag.txt, the run
                  with -XX:+UnlockDiagnosticVMOptions; on JDK 16 and later most intrinsic
                  flags are diagnostic and missing from the plain printflagsfinal-r1.txt)
  --out-csv FILE  Long CSV output
  --out-md FILE   Markdown output; a flag that a JDK does not have is shown as an em dash
  -h, --help      Show this help

Origin column: JDK 9 and later print the origin of each value (default, ergonomic,
command line). JDK 8 does not; there the origin is "default" for "=" and "changed" for ":=".

Exit codes: 0 success, 1 runtime error, 2 usage error.
EOF
}

IN=""
FLAGS="$SCRIPT_DIR/flags.txt"
FILE="printflagsfinal-diag.txt"
OUT_CSV=""
OUT_MD=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --in) need_arg "$@"; IN="$2"; shift 2 ;;
    --flags) need_arg "$@"; FLAGS="$2"; shift 2 ;;
    --file) need_arg "$@"; FILE="$2"; shift 2 ;;
    --out-csv) need_arg "$@"; OUT_CSV="$2"; shift 2 ;;
    --out-md) need_arg "$@"; OUT_MD="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$IN" ] || usage_error "--in is required"
[ -n "$OUT_CSV" ] || usage_error "--out-csv is required"
[ -n "$OUT_MD" ] || usage_error "--out-md is required"
_matches "$FILE" '^[A-Za-z0-9._-]+$' || usage_error "invalid --file '$FILE'"
[ -d "$IN" ] || die "--in $IN is not a directory"
[ -r "$FLAGS" ] || die "flags file not found: $FLAGS"

FLAG_LIST="$(grep -Ev '^[[:space:]]*(#|$)' "$FLAGS" | tr -d ' \r')"
[ -n "$FLAG_LIST" ] || die "no flags in $FLAGS"

# parse FILE: prints "name<TAB>value<TAB>origin" for every flag line of a PrintFlagsFinal file.
parse() {
  awk '
    $3 == "=" || $3 == ":=" {
      name = $2; op = $3
      rest = $0
      sub(/^[^=]*:?= */, "", rest)       # text after the operator
      brace = index(rest, "{")
      value = (brace > 0) ? substr(rest, 1, brace - 1) : rest
      gsub(/^ +| +$/, "", value)
      groups = (brace > 0) ? substr(rest, brace) : ""
      n = 0
      while (match(groups, /\{[^}]*\}/)) {
        n++; last = substr(groups, RSTART + 1, RLENGTH - 2)
        groups = substr(groups, RSTART + RLENGTH)
      }
      if (n >= 2) origin = last
      else origin = (op == ":=") ? "changed" : "default"
      if (!(name in seen)) { seen[name] = 1; printf "%s\t%s\t%s\n", name, value, origin }
    }' "$1"
}

csv_field() { # quote a CSV field when it contains a comma or a quote
  case "$1" in
    *,* | *\"*) printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

mkdir -p "$(dirname "$OUT_CSV")" "$(dirname "$OUT_MD")"
init_tmpdir
printf 'host,jdk_id,flag,value,origin,present\n' >"$OUT_CSV"
: >"$OUT_MD"

found=0
for hostdir in "$IN"/*; do
  [ -d "$hostdir" ] || continue
  host="$(basename "$hostdir")"
  ids=""
  for jdkdir in "$hostdir"/*; do
    [ -f "$jdkdir/$FILE" ] || continue
    id="$(basename "$jdkdir")"
    ids="$ids $id"
    parse "$jdkdir/$FILE" >"$TMP_WORK/$host--$id.tsv"
  done
  [ -n "$ids" ] || continue
  found=1
  # Markdown header for this host
  {
    printf '## %s\n\n| Flag |' "$host"
    for id in $ids; do printf ' %s |' "$id"; done
    printf '\n|---|'
    for _ in $ids; do printf -- '---|'; done
    printf '\n'
  } >>"$OUT_MD"
  for flag in $FLAG_LIST; do
    printf '| %s |' "$flag" >>"$OUT_MD"
    for id in $ids; do
      line="$(awk -F'\t' -v f="$flag" '$1 == f { print; exit }' "$TMP_WORK/$host--$id.tsv")"
      if [ -n "$line" ]; then
        value="$(printf '%s' "$line" | cut -f2)"
        origin="$(printf '%s' "$line" | cut -f3)"
        printf '%s,%s,%s,%s,%s,true\n' "$host" "$id" "$flag" "$(csv_field "$value")" "$(csv_field "$origin")" >>"$OUT_CSV"
        printf ' %s |' "${value:-(empty)}" >>"$OUT_MD"
      else
        printf '%s,%s,%s,,,false\n' "$host" "$id" "$flag" >>"$OUT_CSV"
        printf ' — |' >>"$OUT_MD"
      fi
    done
    printf '\n' >>"$OUT_MD"
  done
  printf '\n' >>"$OUT_MD"
done

[ "$found" = 1 ] || die "no $FILE files found under $IN/<host>/<jdk-id>/"
echo "Wrote $OUT_CSV and $OUT_MD"

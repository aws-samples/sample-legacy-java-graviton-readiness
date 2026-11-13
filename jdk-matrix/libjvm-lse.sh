#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Counts Armv8.1 LSE atomic instructions and load-exclusive/store-exclusive pairs in the
# machine code of libjvm.so, and the outline-atomics helper symbols (__aarch64_*). This shows
# whether the JVM's own C++ code was built to use LSE, which is independent of the UseLSE
# flag (UseLSE controls the code that the JIT compilers generate).
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME JAVA_HOME

Prints key=value lines: the libjvm.so path, its SHA-256, instruction counts per family
(LSE: cas, casp, ldadd, ldclr, ldeor, ldset, ldsmax, ldsmin, ldumax, ldumin, swp; exclusive:
ldxr, ldaxr, stxr, stlxr and their byte, halfword and pair forms) and the number of
__aarch64_ helper symbols in the dynamic and the static symbol tables. Needs objdump and nm
(binutils) that understand aarch64 ELF files.

Exit codes: 0 success, 1 runtime error (no libjvm.so, not an aarch64 ELF file), 2 usage error.
EOF
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  "") usage_error "JAVA_HOME is required" ;;
  -*) usage_error "unknown argument '$1'" ;;
esac
[ "$#" -eq 1 ] || usage_error "exactly one JAVA_HOME is expected"
HOME_DIR="$1"

LIB=""
for c in "$HOME_DIR/lib/server/libjvm.so" "$HOME_DIR/jre/lib/aarch64/server/libjvm.so"; do
  if [ -f "$c" ]; then LIB="$c"; break; fi
done
[ -n "$LIB" ] || die "no aarch64 server libjvm.so under $HOME_DIR"
require_cmd objdump nm awk
objdump -f "$LIB" | grep -q 'architecture: aarch64' || die "$LIB is not an aarch64 ELF file"

init_tmpdir
objdump -d --no-show-raw-insn "$LIB" >"$TMP_WORK/disasm" || die "objdump failed on $LIB"

printf 'libjvm=%s\n' "${LIB#"$HOME_DIR"/}"
printf 'libjvm_sha256=%s\n' "$(sha256_of "$LIB")"
# Instruction lines look like "  4a2f10:	casal	w1, w2, [x0]"; the mnemonic is field 2.
awk -F'\t' '
  NF >= 2 && $1 ~ /^ *[0-9a-f]+:$/ {
    m = $2; sub(/ .*/, "", m)
    if (m ~ /^(cas|casp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin|swp)(a|al|l)?(b|h)?$/) {
      fam = m; sub(/(a|al|l)?(b|h)?$/, "", fam)
      if (m ~ /^casp/) fam = "casp"
      lse[fam]++; lse_total++
    } else if (m ~ /^(ldxr|ldaxr|stxr|stlxr|ldxp|ldaxp|stxp|stlxp)(b|h)?$/) {
      excl[m]++; excl_total++
    }
  }
  END {
    n = split("cas casp ldadd ldclr ldeor ldset ldsmax ldsmin ldumax ldumin swp", f, " ")
    for (i = 1; i <= n; i++) printf "lse_%s=%d\n", f[i], lse[f[i]] + 0
    printf "lse_total=%d\n", lse_total + 0
    n = split("ldxr ldaxr stxr stlxr ldxp ldaxp stxp stlxp", e, " ")
    for (i = 1; i <= n; i++) printf "excl_%s=%d\n", e[i], excl[e[i]] + excl[e[i] "b"] + excl[e[i] "h"]
    printf "excl_total=%d\n", excl_total + 0
  }' "$TMP_WORK/disasm"
dyn="$(nm -D "$LIB" 2>/dev/null | grep -c ' __aarch64_' || true)"
static="$(nm "$LIB" 2>/dev/null | grep -c ' __aarch64_' || true)"
printf 'outline_atomics_dynsym=%s\n' "${dyn:-0}"
printf 'outline_atomics_symtab=%s\n' "${static:-0}"

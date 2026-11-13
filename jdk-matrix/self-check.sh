#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Checks one JDK on this host (or inside this container) against the version thresholds
# documented in the README: cgroup v2 support, the AArch64 port of JDK 8, a known AArch64 C2
# addressing bug, container support, 2 MB thread stacks with transparent huge pages, and
# native libraries that export JavaCritical_ functions. Read-only: it runs java -version style
# commands, reads /proc and /sys, and runs nm on the native libraries it is given.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--native-libs PATH]... [JAVA_HOME]

Checks the JDK in JAVA_HOME (default: \$JAVA_HOME, else the java on PATH) and prints one line
per check: PASS, WARN or INFO, followed by the JVM's own view of the system
(java -XshowSettings:system -version, on JDKs that support it).

Options:
  --native-libs PATH  A native library of the application, or a directory that is searched
                      for *.so and *.so.* files; repeat for more paths. Libraries packed in
                      JAR files must be extracted first. Needs nm (binutils).
  -h, --help          Show this help

Checks:
  cgroup-v2        cgroup v2 host and a JDK that reads only cgroup v1
                   (JDK 8 before 8u372, JDK 11 before 11.0.16, JDK 9, 10, 12 to 14)
  container        UseContainerSupport absent (JDK 8 before 8u191) or disabled
  aarch64-port     JDK 8 before 8u292 on AArch64: built from the separate AArch64 port
                   repository, before JDK-8257192 integrated the port into jdk8u
  jdk-8267689      JDK 8 on AArch64 without the fix for JDK-8267689 (C2 bad shift in an
                   indexed address, reachable through sun.misc.Unsafe): before 8u302, and
                   Corretto before 8.292.10.2
  stack-thp        AArch64 ThreadStackSize of 2048 KB with transparent huge pages "always":
                   reported as INFO, not WARN. Thread stacks can be backed by 2 MB huge pages
                   (JDK-8303215). The lab measured about 2 MiB RSS per thread for 2048 KB
                   stacks on Amazon Linux 2 (kernel 5.10), and 12.9 to 18.3 KiB more per thread
                   on Amazon Linux 2023 (kernel 6.18, which does not use huge pages for thread
                   stacks); check RSS on your own kernel
  javacritical     JDK 8 on AArch64 with CriticalJNINatives=true (Corretto 8) and a library
                   given with --native-libs that exports JavaCritical_ functions
                   (nm -D --defined-only LIB | grep JavaCritical_): the JVM exits the first time
                   it compiles such a native method; start it with -XX:-CriticalJNINatives

Exit codes: 0 no WARN, 3 at least one WARN, 1 runtime error, 2 usage error.
EOF
}

JAVA_HOME_ARG=""
NATIVE_LIBS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --native-libs)
      need_arg "$@"
      [ -e "$2" ] || usage_error "--native-libs: no such file or directory '$2'"
      NATIVE_LIBS+=("$2")
      shift 2
      ;;
    -*) usage_error "unknown argument '$1'" ;;
    *)
      [ -z "$JAVA_HOME_ARG" ] || usage_error "at most one JAVA_HOME is expected"
      JAVA_HOME_ARG="$1"
      shift
      ;;
  esac
done
if [ -n "$JAVA_HOME_ARG" ]; then
  JAVA="$JAVA_HOME_ARG/bin/java"
elif [ -n "${JAVA_HOME:-}" ]; then
  JAVA="$JAVA_HOME/bin/java"
else
  JAVA="$(command -v java || true)"
fi
if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
  die "no java launcher found (give JAVA_HOME as the argument)"
fi

MOUNTINFO="${SELFCHECK_MOUNTINFO:-/proc/self/mountinfo}"
THP_FILE="${SELFCHECK_THP:-/sys/kernel/mm/transparent_hugepage/enabled}"

WARNED=0
pass() { printf 'PASS %-13s %s\n' "$1" "$2"; }
warn_check() {
  printf 'WARN %-13s %s\n' "$1" "$2"
  WARNED=1
}
note() { printf 'INFO %-13s %s\n' "$1" "$2"; }

VERSION_OUT="$("$JAVA" -version 2>&1)" || die "$JAVA -version failed"
VERSION="$(printf '%s\n' "$VERSION_OUT" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
RUNTIME="$(printf '%s\n' "$VERSION_OUT" | sed -n '2p')"
case "$VERSION" in
  1.8.0_*)
    MAJOR=8
    UPDATE="${VERSION#1.8.0_}"
    UPDATE="${UPDATE%%[!0-9]*}"
    ;;
  1.*) die "unsupported Java version $VERSION" ;;
  *)
    MAJOR="${VERSION%%[.+-]*}"
    rest="${VERSION#"$MAJOR"}"
    case "$rest" in
      .*.*) rest="${rest#.*.}"; UPDATE="${rest%%[!0-9]*}" ;;
      *) UPDATE=0 ;;
    esac
    ;;
esac
if ! _matches "$MAJOR" '^[0-9]+$' || ! _matches "${UPDATE:-x}" '^[0-9]+$'; then
  die "cannot parse the Java version '$VERSION'"
fi
CORRETTO_BUILD="$(printf '%s\n' "$RUNTIME" | sed -n 's/.*Corretto-\([0-9.]*\).*/\1/p')"
ARCH="$("$JAVA" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *os\.arch = //p' | head -n 1)"
FLAGS="$("$JAVA" -XX:+PrintFlagsFinal -version 2>/dev/null || true)"
# awk reads all of its input: an early exit would make printf fail with SIGPIPE (exit 141 under
# pipefail) when FLAGS is larger than the pipe buffer.
flag() { printf '%s\n' "$FLAGS" | awk -v f="$1" '!done && ($3 == "=" || $3 == ":=") && $2 == f { print $4; done = 1 }'; }

note jdk "version $VERSION (feature $MAJOR, update $UPDATE), os.arch ${ARCH:-unknown}${CORRETTO_BUILD:+, Corretto $CORRETTO_BUILD}"

# cgroup version: file system type of the /sys/fs/cgroup mount as this process sees it.
CGROUP="$(cgroup_fs_type "$MOUNTINFO")"
CG="$(cgroup_version "$MOUNTINFO")"
note cgroup "/sys/fs/cgroup type '${CGROUP:-not found}' (cgroup $CG)"

V2_OK=1
case "$MAJOR" in
  8) [ "$UPDATE" -ge 372 ] || V2_OK=0 ;;
  9 | 10 | 12 | 13 | 14) V2_OK=0 ;;
  11) [ "$UPDATE" -ge 16 ] || V2_OK=0 ;;
esac
if [ "$CG" = v2 ] && [ "$V2_OK" = 0 ]; then
  warn_check cgroup-v2 "this JDK reads only cgroup v1: on this cgroup v2 host it sizes the heap and thread pools from the host's memory and CPUs, not the container limits (cgroup v2 support: JDK-8230305, JDK 8u372, 11.0.16, 15)"
elif [ "$CG" = v2 ]; then
  pass cgroup-v2 "this JDK reads cgroup v2 limits"
elif [ "$V2_OK" = 0 ]; then
  note cgroup-v2 "not a cgroup v2 host; this JDK would not read cgroup v2 limits (needs 8u372, 11.0.16 or 15+)"
else
  pass cgroup-v2 "this JDK reads cgroup v1 and v2 limits"
fi

UCS="$(flag UseContainerSupport)"
if [ -z "$UCS" ]; then
  warn_check container "UseContainerSupport does not exist in this JDK (added in JDK 10 and 8u191)"
elif [ "$UCS" = false ]; then
  warn_check container "UseContainerSupport is false: the JVM ignores container limits"
else
  pass container "UseContainerSupport=true"
fi

if [ "$ARCH" = aarch64 ] && [ "$MAJOR" = 8 ]; then
  if [ "$UPDATE" -lt 292 ]; then
    warn_check aarch64-port "JDK 8 before 8u292 was built from the separate AArch64 port repository, before JDK-8257192 integrated the port into jdk8u (Corretto: 8.292.10.1 switched from the IcedTea-based port)"
  else
    pass aarch64-port "JDK 8 update $UPDATE contains the AArch64 port of jdk8u (JDK-8257192, 8u292)"
  fi
  FIXED=1
  if [ "$UPDATE" -lt 292 ]; then
    FIXED=0
  elif [ "$UPDATE" -lt 302 ]; then
    # 8u292: only the Corretto respin 8.292.10.2 has the fix.
    case "$CORRETTO_BUILD" in
      8.292.10.1 | "") FIXED=0 ;;
    esac
  fi
  if [ "$FIXED" = 0 ]; then
    warn_check jdk-8267689 "no fix for JDK-8267689 (AArch64 C2 bad shift in indexed addressing, reachable through sun.misc.Unsafe; fixed in 8u302 and Corretto 8.292.10.2)"
  else
    pass jdk-8267689 "contains the fix for JDK-8267689"
  fi
fi

if [ "$ARCH" = aarch64 ]; then
  TSS="$(flag ThreadStackSize)"
  THP=""
  if [ -r "$THP_FILE" ]; then THP="$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' "$THP_FILE")"; fi
  note stack-thp "ThreadStackSize=${TSS:-unknown} KB, transparent_hugepage=${THP:-unknown}"
  if [ "$TSS" = 2048 ] && [ "$THP" = always ]; then
    # INFO, not WARN: whether a stack gets a 2 MB huge page depends on the kernel. Measured with
    # THP 'always': about 2 MiB RSS per thread for 2048 KB stacks (187.6 to 200.5 KiB for 2040 KB)
    # on Amazon Linux 2 (kernel 5.10); 12.9 to 18.3 KiB more per thread on Amazon Linux 2023
    # (kernel 6.18).
    note stack-thp "2048 KB thread stacks with THP 'always': a stack can be backed by a 2 MB huge page (JDK-8303215 changed the default to 2040 KB in 8u512). Measured about 2 MiB RSS per thread on Amazon Linux 2 (kernel 5.10), not on Amazon Linux 2023 (kernel 6.18); compare RSS per thread with THP 'madvise' on your kernel"
  else
    pass stack-thp "no 2048 KB stack and THP 'always' combination"
  fi
fi

# javacritical: the lab's method, nm -D --defined-only LIB | grep JavaCritical_, on every library
# given with --native-libs. On AArch64, Corretto 8 builds with CriticalJNINatives=true exit (exit
# code 134, Unimplemented() in sharedRuntime_aarch64.cpp) the first time they compile a native
# method that has a JavaCritical_ entry point. The JDK's own libraries export none.
if [ "${#NATIVE_LIBS[@]}" -eq 0 ]; then
  note javacritical "not checked: give the application's native libraries with --native-libs PATH"
elif ! command -v nm >/dev/null 2>&1; then
  note javacritical "not checked: nm (binutils) not found; run nm -D --defined-only LIB | grep JavaCritical_ on each library"
else
  LIB_FILES="$(for p in "${NATIVE_LIBS[@]}"; do
    if [ -d "$p" ]; then find "$p" -type f \( -name '*.so' -o -name '*.so.*' \); else printf '%s\n' "$p"; fi
  done | LC_ALL=C sort -u)"
  N_LIBS=0
  N_UNREADABLE=0
  HITS=""
  while IFS= read -r so; do
    [ -n "$so" ] || continue
    N_LIBS=$((N_LIBS + 1))
    if ! syms="$(nm -D --defined-only "$so" 2>/dev/null)"; then
      N_UNREADABLE=$((N_UNREADABLE + 1))
      continue
    fi
    # grep reads all of its input, so printf cannot get SIGPIPE.
    found="$(printf '%s\n' "$syms" | grep 'JavaCritical_' | awk -v f="$so" '{ print "  " f ": " $NF }' || true)"
    if [ -n "$found" ]; then HITS="${HITS}${found}"$'\n'; fi
  done <<EOF
$LIB_FILES
EOF
  SCANNED="$N_LIBS libraries scanned"
  if [ "$N_LIBS" = 1 ]; then SCANNED="1 library scanned"; fi
  if [ "$N_UNREADABLE" -gt 0 ]; then SCANNED="$SCANNED, $N_UNREADABLE not readable by nm"; fi
  CJN="$(flag CriticalJNINatives)"
  if [ "$N_LIBS" -eq 0 ]; then
    note javacritical "no *.so files found in the --native-libs paths"
  elif [ -z "$HITS" ]; then
    pass javacritical "no JavaCritical_ functions exported ($SCANNED)"
  else
    N_SYMS="$(printf '%s' "$HITS" | grep -c . || true)"
    if [ "$ARCH" = aarch64 ] && [ "$MAJOR" = 8 ] && [ "$CJN" = true ]; then
      warn_check javacritical "$N_SYMS JavaCritical_ functions exported ($SCANNED) and CriticalJNINatives=true: this JVM exits (exit code 134) the first time it compiles such a native method; start it with -XX:-CriticalJNINatives"
    elif [ "$ARCH" = aarch64 ] && [ "$MAJOR" = 8 ]; then
      pass javacritical "$N_SYMS JavaCritical_ functions exported ($SCANNED), but CriticalJNINatives=${CJN:-unknown} in this JDK; do not turn it on"
    else
      note javacritical "$N_SYMS JavaCritical_ functions exported ($SCANNED); with Corretto 8 on Graviton (AArch64) start the JVM with -XX:-CriticalJNINatives"
    fi
    printf '%s' "$HITS"
  fi
fi

echo "JVM view of the system (-XshowSettings:system):"
"$JAVA" -XshowSettings:system -version 2>&1 | sed -n '/version "/q;s/^/  | /p' || true

if [ "$WARNED" = 1 ]; then exit 3; fi
exit 0

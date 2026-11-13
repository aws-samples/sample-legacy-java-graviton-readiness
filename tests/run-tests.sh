#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Offline tests for the scripts of this repository. Every external tool the scripts call
# (aws, eksctl, kubectl, docker, journalctl, objdump, nm, timeout, uname) is replaced by a
# stub in tests/stubs that logs its arguments and prints placeholder data; JDKs are replaced
# by small fake launchers created in a temporary directory. Nothing contacts AWS or the
# network. The test cases are in tests/cases-*.sh.
#
# Java tests run only when JAVA8_HOME is set (and also on JAVA21_HOME when that is set):
# they compile the probes with -Xlint:all -Werror and run their self-tests.
# Usage: bash tests/run-tests.sh [TEST_NAME...]   Needs bash 3.2 or later, jq and python3.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STUBS="$TESTS_DIR/stubs"
# shellcheck disable=SC2034  # used by the sourced tests/cases-*.sh files
FIXTURES="$TESTS_DIR/fixtures"

JQ_BIN="$(command -v jq)" || {
  echo "jq is required to run the tests" >&2
  exit 1
}
PY_BIN="$(command -v python3)" || {
  echo "python3 is required to run the tests" >&2
  exit 1
}
ROOT_TMP="$(mktemp -d)"
trap 'rm -rf -- "$ROOT_TMP"' EXIT
# Only the stubs, jq, python3 and the base system directories are on PATH for the scripts.
mkdir -p "$ROOT_TMP/tools"
ln -s "$JQ_BIN" "$ROOT_TMP/tools/jq"
ln -s "$PY_BIN" "$ROOT_TMP/tools/python3"
TEST_PATH="$STUBS:$ROOT_TMP/tools:/usr/bin:/bin"

repo_listing() { (cd "$REPO_DIR" && find . | LC_ALL=C sort); }
BEFORE="$(repo_listing)"

# ---- helpers -----------------------------------------------------------------------------------
CASE_DIR=""
OUT=""
RC=0
STUB_LOG=""

fail() {
  printf '    FAIL: %s\n' "$*"
  if [ -n "$OUT" ] && [ -f "$OUT" ]; then
    printf '    --- output ---\n'
    sed 's/^/    | /' "$OUT" | head -n 60
  fi
  exit 1
}

# run_script PATH [ARGS...]: runs REPO/PATH in the case directory with stdin from /dev/null
# (not a terminal) and records the combined output in $OUT and the exit code in $RC.
run_script() {
  local name="$1"
  shift
  OUT="$CASE_DIR/out.txt"
  RC=0
  (
    cd "$CASE_DIR"
    env -i HOME="$CASE_DIR/home" PATH="$TEST_PATH" TMPDIR="$CASE_DIR/tmp" LANG=C \
      STUB_LOG="$STUB_LOG" \
      AWS_CONFIG_FILE="$CASE_DIR/no-aws-config" AWS_SHARED_CREDENTIALS_FILE="$CASE_DIR/no-aws-credentials" \
      AWS_EC2_METADATA_DISABLED=true KUBECONFIG="$CASE_DIR/no-kubeconfig" \
      ${STUB_ENV[@]+"${STUB_ENV[@]}"} \
      bash "$REPO_DIR/$name" "$@"
  ) </dev/null >"$OUT" 2>&1 || RC=$?
}

# stub_env VAR=VALUE...: environment for the next run_script calls in this case.
STUB_ENV=()
stub_env() { STUB_ENV+=("$@"); }

assert_exit() {
  [ "$RC" -eq "$1" ] || fail "expected exit code $1, got $RC"
}
assert_contains() {
  grep -Fq -- "$1" "$OUT" || fail "output does not contain: $1"
}
assert_not_contains() {
  if grep -Fq -- "$1" "$OUT"; then fail "output contains: $1"; fi
}
assert_called() {
  grep -Fq -- "$1" "$STUB_LOG" || fail "no stub call contains: $1"
}
assert_not_called() {
  if grep -Fq -- "$1" "$STUB_LOG"; then fail "unexpected stub call: $(grep -F -- "$1" "$STUB_LOG" | head -n 1)"; fi
}
# assert_order A B: the first call containing A comes before the first call containing B.
assert_order() {
  local a b
  a="$(grep -nF -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" "$STUB_LOG" | head -n 1 | cut -d: -f1)"
  if [ -z "$a" ] || [ -z "$b" ]; then fail "missing call: $1 or $2"; fi
  [ "$a" -lt "$b" ] || fail "call '$1' does not come before '$2'"
}
assert_file() {
  [ -s "$1" ] || fail "missing or empty file: $1"
}
assert_file_exists() {
  [ -e "$1" ] || fail "missing file: $1"
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

# fake_jdk DIR VERSION: a fake JDK whose java prints a version, the PrintFlagsFinal fixture
# FAKE_FLAGS (if set at run time), and accepts any other arguments; javac succeeds.
fake_jdk() {
  mkdir -p "$1/bin"
  cat >"$1/bin/java" <<EOF
#!/bin/bash
# fake java launcher for tests
for a in "\$@"; do
  case "\$a" in
    -XX:+PrintFlagsFinal) [ -n "\${FAKE_FLAGS:-}" ] && cat "\$FAKE_FLAGS" ;;
    -XshowSettings:system) echo "Operating System Metrics:" >&2; echo "    Provider: cgroupv2" >&2 ;;
    -XshowSettings:properties) echo "    os.arch = \${FAKE_ARCH:-aarch64}" >&2 ;;
  esac
done
echo "openjdk version \"\${FAKE_VERSION:-$2}\"" >&2
echo "\${FAKE_RUNTIME:-OpenJDK Runtime Environment (build $2)}" >&2
EOF
  printf '#!/bin/bash\nexit 0\n' >"$1/bin/javac"
  chmod 755 "$1/bin/java" "$1/bin/javac"
}

# ---- test cases --------------------------------------------------------------------------------
for f in "$TESTS_DIR"/cases-*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

# ---- runner ------------------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  TESTS="$*"
else
  TESTS="$(declare -F | awk '{print $3}' | grep '^test_')"
fi

PASS=0
FAILED=0
SKIPPED=0
for t in $TESTS; do
  CASE_DIR="$ROOT_TMP/$t"
  mkdir -p "$CASE_DIR/home" "$CASE_DIR/tmp"
  STUB_LOG="$CASE_DIR/stub.log"
  : >"$STUB_LOG"
  STUB_ENV=()
  OUT=""
  rc=0
  ("$t") || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$t"
  elif [ "$rc" -eq 77 ]; then
    SKIPPED=$((SKIPPED + 1))
    printf 'skip %s\n' "$t"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL %s\n' "$t"
  fi
done

AFTER="$(repo_listing)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL the test run changed the repository file list:"
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") || true
  FAILED=$((FAILED + 1))
fi

printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]

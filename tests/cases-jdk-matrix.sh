#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Test cases for lib/fetch-jdk.sh, the jdk-matrix scripts and the Java programs. Sourced by
# tests/run-tests.sh.

# ---- lib/fetch-jdk.sh -------------------------------------------------------------------------
test_fetch_list() {
  run_script lib/fetch-jdk.sh --list
  assert_exit 0
  [ "$(wc -l <"$OUT" | tr -d ' ')" = 27 ] || fail "expected 27 catalog rows, got $(wc -l <"$OUT")"
  assert_contains "corretto-8.292.10.2"
  assert_contains "temurin-8u372-b07"
  # every row has an https URL and a 64-hex SHA-256
  [ "$(awk -F, '$1 !~ /^#/ && $1 != "jdk_id" && $6 ~ /^https:\/\// && $7 ~ /^[0-9a-f]{64}$/' "$REPO_DIR/lib/jdks.csv" | wc -l | tr -d ' ')" = 27 ] ||
    fail "catalog rows without https URL or SHA-256"
}

# make_tarball DIR NAME: a tarball DIR/NAME.tar.gz with one top directory and bin/java.
make_tarball() {
  mkdir -p "$1/src/$2/bin"
  printf '#!/bin/sh\necho fake\n' >"$1/src/$2/bin/java"
  chmod 755 "$1/src/$2/bin/java"
  (cd "$1/src" && tar -czf "../$2.tar.gz" "$2")
}

# fixture_catalog FILE ROWS...: a catalog with the header and the given rows.
fixture_catalog() {
  local f="$1"
  shift
  printf 'jdk_id,vendor,feature,version,arch,url,sha256,vendor_alg,vendor_checksum,checksum_source,release_page\n' >"$f"
  printf '%s\n' "$@" >>"$f"
}

test_fetch_good_bad_existing() {
  local good sha
  make_tarball "$CASE_DIR" fakejdk-1
  good="$CASE_DIR/fakejdk-1.tar.gz"
  sha="$(sha256 "$good")"
  fixture_catalog "$CASE_DIR/catalog.csv" \
    "corretto-8.999.01.1,corretto,8,8.999.01.1,aarch64,file://$good,$sha,sha256,$sha,test,none" \
    "corretto-8.999.02.1,corretto,8,8.999.02.1,aarch64,file://$good,$(printf '%064d' 0),sha256,x,test,none" \
    "corretto-8.999.03.1,corretto,8,8.999.03.1,aarch64,http://example.com/x.tar.gz,$sha,sha256,x,test,none"
  stub_env JDK_CATALOG="$CASE_DIR/catalog.csv"
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "file:// URLs are allowed only with FETCH_JDK_ALLOW_FILE=1"
  stub_env FETCH_JDK_ALLOW_FILE=1
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch aarch64 --dest "$CASE_DIR/jdks" \
    --log "$CASE_DIR/results/fetch.csv" --host-label test-host --cache "$CASE_DIR/cache"
  assert_exit 0
  [ -x "$CASE_DIR/jdks/corretto-8.999.01.1/bin/java" ] || fail "JDK not extracted (top directory not stripped?)"
  # the log directory (results/ in the README run script) does not exist yet
  assert_file_contains "$CASE_DIR/results/fetch.csv" "test-host,corretto-8.999.01.1,aarch64,file://$good,sha256,$sha,$sha,ok"
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 0
  assert_contains "already present"
  # wrong checksum: rejected, nothing extracted
  run_script lib/fetch-jdk.sh --id corretto-8.999.02.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "SHA-256 mismatch"
  [ ! -e "$CASE_DIR/jdks/corretto-8.999.02.1" ] || fail "a build with a bad checksum was extracted"
  # plain http is refused
  run_script lib/fetch-jdk.sh --id corretto-8.999.03.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "must use https"
  # an existing directory that is not this build is never overwritten
  mkdir -p "$CASE_DIR/other/corretto-8.999.01.1"
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch aarch64 --dest "$CASE_DIR/other"
  assert_exit 1
  assert_contains "exists but is not the catalog build"
  # unknown ID and bad arch
  run_script lib/fetch-jdk.sh --id corretto-8.000.00.0 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "no catalog entry"
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch sparc --dest "$CASE_DIR/jdks"
  assert_exit 2
}

test_fetch_large_catalog() {
  # The entry is the first row of a catalog larger than a pipe buffer: the lookup must read the
  # whole catalog, or catalog_rows dies of SIGPIPE (exit 141, no message) under pipefail.
  local good sha i
  make_tarball "$CASE_DIR" fakejdk-1
  good="$CASE_DIR/fakejdk-1.tar.gz"
  sha="$(sha256 "$good")"
  fixture_catalog "$CASE_DIR/catalog.csv" "corretto-8.999.01.1,corretto,8,8.999.01.1,aarch64,file://$good,$sha,sha256,$sha,test,none"
  i=0
  while [ "$i" -lt 2000 ]; do
    printf 'corretto-8.998.%s.1,corretto,8,x,aarch64,https://example.com/padding-row-%s.tar.gz,%064d,sha256,x,test,none\n' \
      "$i" "$i" 0 >>"$CASE_DIR/catalog.csv"
    i=$((i + 1))
  done
  stub_env JDK_CATALOG="$CASE_DIR/catalog.csv" FETCH_JDK_ALLOW_FILE=1
  run_script lib/fetch-jdk.sh --id corretto-8.999.01.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 0
  [ -x "$CASE_DIR/jdks/corretto-8.999.01.1/bin/java" ] || fail "JDK not extracted"
}

test_fetch_rejects_traversal() {
  local bad sha
  bad="$CASE_DIR/bad.tar.gz"
  python3 - "$bad" <<'EOF'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name in ("top/bin/java", "top/../../evil"):
        data = b"x"
        info = tarfile.TarInfo(name)
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
EOF
  sha="$(sha256 "$bad")"
  fixture_catalog "$CASE_DIR/catalog.csv" "corretto-8.999.04.1,corretto,8,x,aarch64,file://$bad,$sha,sha256,x,test,none"
  stub_env JDK_CATALOG="$CASE_DIR/catalog.csv" FETCH_JDK_ALLOW_FILE=1
  run_script lib/fetch-jdk.sh --id corretto-8.999.04.1 --arch aarch64 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "absolute or .. member paths"
  if [ -e "$CASE_DIR/evil" ] || [ -e "$CASE_DIR/jdks/corretto-8.999.04.1" ]; then
    fail "traversal tarball was extracted"
  fi
}

test_fetch_arch_auto() {
  stub_env STUB_UNAME_M=x86_64
  run_script lib/fetch-jdk.sh --id corretto-8.000.00.0 --dest "$CASE_DIR/jdks"
  assert_exit 1
  assert_contains "no catalog entry for corretto-8.000.00.0 (x64)"
}

# ---- jdk-matrix/flags-to-csv.sh -----------------------------------------------------------------
test_flags_to_csv() {
  run_script jdk-matrix/flags-to-csv.sh --in "$FIXTURES/flags" --out-csv "$CASE_DIR/f.csv" --out-md "$CASE_DIR/f.md"
  assert_exit 0
  local csv="$CASE_DIR/f.csv" md="$CASE_DIR/f.md"
  assert_file_contains "$csv" "host,jdk_id,flag,value,origin,present"
  assert_file_contains "$csv" "host-a,corretto-8.372.07.1,MaxHeapSize,4294967296,changed,true"
  assert_file_contains "$csv" "host-a,corretto-8.372.07.1,ThreadStackSize,2048,default,true"
  assert_file_contains "$csv" "host-a,corretto-8.372.07.1,UseLSE,true,default,true"
  assert_file_contains "$csv" "host-a,corretto-8.372.07.1,UseSVE,,,false"
  assert_file_contains "$csv" "host-a,corretto-8.372.07.1,UseCRC32CIntrinsics,,,false"
  assert_file_contains "$csv" "host-a,corretto-11.0.16.8.1,MaxHeapSize,4294967296,ergonomic,true"
  assert_file_contains "$csv" "host-a,corretto-11.0.16.8.1,UseCRC32CIntrinsics,true,default,true"
  assert_file_contains "$csv" "host-a,corretto-21.0.13.0.11,UseSVE,1,default,true"
  assert_file_contains "$csv" "host-a,corretto-21.0.13.0.11,ThreadStackSize,2040,default,true"
  # JDK 16+ diagnostic flags are read from the unlocked run by default
  assert_file_contains "$csv" "host-a,corretto-21.0.13.0.11,UseAESIntrinsics,true,default,true"
  assert_file_contains "$csv" "host-a,corretto-21.0.13.0.11,UseCRC32CIntrinsics,true,default,true"
  # one row per host, JDK and flag of flags.txt
  local flags rows
  flags="$(grep -Evc '^[[:space:]]*(#|$)' "$REPO_DIR/jdk-matrix/flags.txt")"
  rows="$(($(wc -l <"$csv") - 1))"
  [ "$rows" -eq $((flags * 3)) ] || fail "expected $((flags * 3)) rows, got $rows"
  assert_file_contains "$md" "## host-a"
  assert_file_contains "$md" "| Flag | corretto-11.0.16.8.1 | corretto-21.0.13.0.11 | corretto-8.372.07.1 |"
  assert_file_contains "$md" "| UseSVE | — | 1 | — |"
  assert_file_contains "$md" "| ThreadStackSize | 2048 | 2040 | 2048 |"
  assert_file_contains "$md" "| UseAESIntrinsics | — | true | — |"
  # the plain run does not print locked diagnostic flags
  run_script jdk-matrix/flags-to-csv.sh --in "$FIXTURES/flags" --file printflagsfinal-r1.txt \
    --out-csv "$CASE_DIR/p.csv" --out-md "$CASE_DIR/p.md"
  assert_exit 0
  assert_file_contains "$CASE_DIR/p.csv" "host-a,corretto-21.0.13.0.11,UseAESIntrinsics,,,false"
  run_script jdk-matrix/flags-to-csv.sh --in "$CASE_DIR" --out-csv "$CASE_DIR/g.csv" --out-md "$CASE_DIR/g.md"
  assert_exit 1
  assert_contains "no printflagsfinal-diag.txt files found"
}

# ---- jdk-matrix/run-matrix.sh -----------------------------------------------------------------
test_run_matrix_fake_jdks() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  fake_jdk "$CASE_DIR/jdks/corretto-21.0.13.0.11" 21.0.13
  mkdir -p "$CASE_DIR/jdks/not-a-jdk/bin" "$CASE_DIR/jdks/zulu-8.1"
  stub_env FAKE_FLAGS="$FIXTURES/flags/host-a/corretto-8.372.07.1/printflagsfinal-r1.txt"
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label mac \
    --repeats 2 --in-docker public.ecr.aws/amazonlinux/amazonlinux:2023 --libjvm-lse
  assert_exit 0
  local d="$CASE_DIR/out/mac/corretto-8.372.07.1"
  for f in version.txt printflagsfinal-r1.txt printflagsfinal-r2.txt printflagsfinal-diag.txt \
    showsettings-system.txt showsettings-vm.txt exit-codes.txt repeats.txt printflagsfinal-docker.txt libjvm-lse.txt; do
    [ -f "$d/$f" ] || fail "missing $f"
  done
  assert_file_contains "$d/repeats.txt" "repeats=2 identical=yes"
  assert_file_contains "$d/exit-codes.txt" "printflagsfinal-r2=0"
  assert_file_contains "$d/exit-codes.txt" "libjvm-lse=1"
  assert_file_contains "$d/version.txt" 'openjdk version "1.8.0_372"'
  [ -d "$CASE_DIR/out/mac/corretto-21.0.13.0.11" ] || fail "second JDK not run"
  [ ! -e "$CASE_DIR/out/mac/zulu-8.1" ] || fail "a directory that is not a JDK was run"
  assert_called "docker run --rm --network none --read-only --tmpfs /tmp --user 10001:10001"
  assert_called "/jdk/bin/java -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlagsFinal -version"
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out2" --host-label mac \
    --jdks corretto-21.0.13.0.11 --repeats 1
  assert_exit 0
  [ ! -e "$CASE_DIR/out2/mac/corretto-8.372.07.1" ] || fail "--jdks did not restrict the run"
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label mac --jdks "a,,b"
  assert_exit 2
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label mac --repeats 11
  assert_exit 2
}

test_run_matrix_detects_unstable_flags() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.372.07.1" 1.8.0_372
  # a java whose PrintFlagsFinal output changes on every call
  cat >"$CASE_DIR/jdks/corretto-8.372.07.1/bin/java" <<EOF
#!/bin/bash
n=\$(cat "$CASE_DIR/count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$CASE_DIR/count"
echo "     intx CICompilerCount = \$n {product}"
EOF
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label mac --repeats 3
  assert_exit 0
  assert_contains "PrintFlagsFinal output differs between repeats"
  assert_file_contains "$CASE_DIR/out/mac/corretto-8.372.07.1/repeats.txt" "identical=no"
}

# ---- jdk-matrix/libjvm-lse.sh -----------------------------------------------------------------
test_libjvm_lse() {
  mkdir -p "$CASE_DIR/jdk8/jre/lib/aarch64/server" "$CASE_DIR/jdk21/lib/server"
  printf 'x' >"$CASE_DIR/jdk8/jre/lib/aarch64/server/libjvm.so"
  printf 'y' >"$CASE_DIR/jdk21/lib/server/libjvm.so"
  run_script jdk-matrix/libjvm-lse.sh "$CASE_DIR/jdk8"
  assert_exit 0
  assert_contains "libjvm=jre/lib/aarch64/server/libjvm.so"
  assert_contains "lse_cas=1"
  assert_contains "lse_ldadd=1"
  assert_contains "lse_swp=1"
  assert_contains "lse_total=3"
  assert_contains "excl_ldaxr=1"
  assert_contains "excl_stlxr=1"
  assert_contains "excl_total=2"
  assert_contains "outline_atomics_dynsym=1"
  assert_contains "outline_atomics_symtab=0"
  run_script jdk-matrix/libjvm-lse.sh "$CASE_DIR/jdk21"
  assert_exit 0
  assert_contains "libjvm=lib/server/libjvm.so"
  stub_env STUB_OBJDUMP_ARCH=i386:x86-64
  run_script jdk-matrix/libjvm-lse.sh "$CASE_DIR/jdk21"
  assert_exit 1
  assert_contains "is not an aarch64 ELF file"
  run_script jdk-matrix/libjvm-lse.sh "$CASE_DIR"
  assert_exit 1
  assert_contains "no aarch64 server libjvm.so"
}

# ---- jdk-matrix/self-check.sh -----------------------------------------------------------------
# self_check VERSION RUNTIME MOUNTINFO THP [FLAGS_FIXTURE]: runs self-check.sh on a fake JDK.
self_check() {
  fake_jdk "$CASE_DIR/jdk" "$1"
  printf '%s\n' "$4" >"$CASE_DIR/thp"
  STUB_ENV=(FAKE_RUNTIME="$2" SELFCHECK_MOUNTINFO="$FIXTURES/$3" SELFCHECK_THP="$CASE_DIR/thp"
    FAKE_FLAGS="${5:-$FIXTURES/flags/host-a/corretto-8.372.07.1/printflagsfinal-r1.txt}")
  run_script jdk-matrix/self-check.sh "$CASE_DIR/jdk"
}

test_self_check_old_jdk8_on_v2() {
  self_check 1.8.0_362 "OpenJDK Runtime Environment Corretto-8.362.08.1 (build 1.8.0_362-b08)" \
    mountinfo-cgroup2.txt "[always] madvise never"
  assert_exit 3
  assert_contains "INFO cgroup        /sys/fs/cgroup type 'cgroup2' (cgroup v2)"
  assert_contains "WARN cgroup-v2"
  assert_contains "PASS container"
  assert_contains "PASS aarch64-port"
  assert_contains "PASS jdk-8267689"
  assert_contains "INFO stack-thp     2048 KB thread stacks"
  assert_not_contains "WARN stack-thp"
  assert_contains "Corretto 8.362.08.1"
  assert_contains "  | Operating System Metrics:"
}

test_self_check_jdk8_372_passes() {
  self_check 1.8.0_372 "OpenJDK Runtime Environment Corretto-8.372.07.1 (build 1.8.0_372-b07)" \
    mountinfo-cgroup2.txt "always [madvise] never"
  assert_exit 0
  assert_contains "PASS cgroup-v2"
  assert_contains "PASS stack-thp"
  assert_not_contains "WARN"
}

test_self_check_aarch64_port_and_8267689() {
  self_check 1.8.0_282 "OpenJDK Runtime Environment Corretto-8.282.08.1 (build 1.8.0_282-b08)" \
    mountinfo-cgroup1.txt "always [madvise] never"
  assert_exit 3
  assert_contains "WARN aarch64-port"
  assert_contains "WARN jdk-8267689"
  assert_contains "INFO cgroup-v2"
  self_check 1.8.0_292 "OpenJDK Runtime Environment Corretto-8.292.10.1 (build 1.8.0_292-b10)" \
    mountinfo-cgroup1.txt "always [madvise] never"
  assert_contains "PASS aarch64-port"
  assert_contains "WARN jdk-8267689"
  self_check 1.8.0_292 "OpenJDK Runtime Environment Corretto-8.292.10.2 (build 1.8.0_292-b10)" \
    mountinfo-cgroup1.txt "always [madvise] never"
  assert_contains "PASS jdk-8267689"
  self_check 1.8.0_292 "OpenJDK Runtime Environment (Temurin)(build 1.8.0_292-b10)" \
    mountinfo-cgroup1.txt "always [madvise] never"
  assert_contains "WARN jdk-8267689"
  self_check 1.8.0_282 "OpenJDK Runtime Environment Corretto-8.282.08.1 (build 1.8.0_282-b08)" \
    mountinfo-cgroup1.txt "[always] madvise never"
  STUB_ENV+=(FAKE_ARCH=amd64)
  run_script jdk-matrix/self-check.sh "$CASE_DIR/jdk"
  assert_exit 0
  assert_not_contains "aarch64-port"
  assert_not_contains "stack-thp"
}

test_self_check_jdk11() {
  self_check 11.0.15 "OpenJDK Runtime Environment Corretto-11.0.15.9.1 (build 11.0.15+9-LTS)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$FIXTURES/flags/host-a/corretto-11.0.16.8.1/printflagsfinal-r1.txt"
  assert_exit 3
  assert_contains "feature 11, update 15"
  assert_contains "WARN cgroup-v2"
  assert_not_contains "aarch64-port"
  self_check 11.0.16 "OpenJDK Runtime Environment Corretto-11.0.16.8.1 (build 11.0.16+8-LTS)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$FIXTURES/flags/host-a/corretto-11.0.16.8.1/printflagsfinal-r1.txt"
  assert_exit 0
  assert_contains "PASS cgroup-v2"
  self_check 21.0.13 "OpenJDK Runtime Environment Corretto-21.0.13.11.1 (build 21.0.13+11-LTS)" \
    mountinfo-cgroup2.txt "[always] madvise never" "$FIXTURES/flags/host-a/corretto-21.0.13.0.11/printflagsfinal-r1.txt"
  assert_exit 0
  assert_contains "ThreadStackSize=2040 KB"
}

test_self_check_no_container_support() {
  printf '     intx ThreadStackSize = 2048 {pd product}\n' >"$CASE_DIR/flags-181.txt"
  self_check 1.8.0_181 "OpenJDK Runtime Environment (build 1.8.0_181-b13)" \
    mountinfo-cgroup1.txt "always [madvise] never" "$CASE_DIR/flags-181.txt"
  assert_exit 3
  assert_contains "WARN container     UseContainerSupport does not exist"
  run_script jdk-matrix/self-check.sh "$CASE_DIR/missing"
  assert_exit 1
  assert_contains "no java launcher found"
}

test_self_check_large_flags_output() {
  # The flags looked up come first, followed by far more text than a pipe buffer holds: flag()
  # must still read all of it, or printf gets SIGPIPE and set -e ends the script (exit 141).
  {
    printf '     bool UseContainerSupport                      = true {product}\n'
    printf '     intx ThreadStackSize                          = 2048 {pd product}\n'
    awk 'BEGIN { for (i = 0; i < 20000; i++) printf "     intx FillerFlag%05d                           = 0 {product}\n", i }'
  } >"$CASE_DIR/flags-large.txt"
  self_check 1.8.0_372 "OpenJDK Runtime Environment Corretto-8.372.07.1 (build 1.8.0_372-b07)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$CASE_DIR/flags-large.txt"
  assert_exit 0
  assert_contains "PASS container     UseContainerSupport=true"
  assert_contains "ThreadStackSize=2048 KB"
  assert_contains "INFO javacritical  not checked: give the application's native libraries with --native-libs PATH"
}

# javacritical_fixtures: fake native libraries (nm-style symbol lines, read by tests/stubs/nm)
# and PrintFlagsFinal excerpts with CriticalJNINatives true and false.
javacritical_fixtures() {
  mkdir -p "$CASE_DIR/app/lib/sub" "$CASE_DIR/clean"
  printf '00001100 T Java_demo_Native_sum\n00001130 T JavaCritical_demo_Native_sum\n' \
    >"$CASE_DIR/app/lib/libcrit.so"
  printf '00001200 T JavaCritical_demo_Other_copy\n' >"$CASE_DIR/app/lib/sub/libother.so.1"
  printf '00001100 T Java_demo_Plain_run\n         U JavaCritical_not_defined\n' \
    >"$CASE_DIR/clean/libplain.so"
  printf 'not-elf\n' >"$CASE_DIR/clean/libbroken.so"
  printf 'JavaCritical_in_a_text_file\n' >"$CASE_DIR/app/lib/README.txt"
  local v
  for v in true false; do
    {
      printf '     bool CriticalJNINatives                        = %s {product}\n' "$v"
      printf '     bool UseContainerSupport                       = true {product}\n'
      printf '     intx ThreadStackSize                           = 2048 {pd product}\n'
    } >"$CASE_DIR/flags-cjn-$v.txt"
  done
}

test_self_check_javacritical_warns_on_corretto8_aarch64() {
  javacritical_fixtures
  self_check 1.8.0_512 "OpenJDK Runtime Environment Corretto-8.512.09.1 (build 1.8.0_512-b09)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$CASE_DIR/flags-cjn-true.txt"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/app/lib" "$CASE_DIR/jdk"
  assert_exit 3
  assert_contains "WARN javacritical  2 JavaCritical_ functions exported (2 libraries scanned) and CriticalJNINatives=true"
  assert_contains "start it with -XX:-CriticalJNINatives"
  assert_contains "  $CASE_DIR/app/lib/libcrit.so: JavaCritical_demo_Native_sum"
  assert_contains "  $CASE_DIR/app/lib/sub/libother.so.1: JavaCritical_demo_Other_copy"
  assert_not_contains "README.txt"
  # the other checks still pass, and the JVM view is still printed after the check
  assert_contains "PASS cgroup-v2"
  assert_contains "  | Operating System Metrics:"
  # a single file argument, and the option given after JAVA_HOME
  run_script jdk-matrix/self-check.sh "$CASE_DIR/jdk" --native-libs "$CASE_DIR/app/lib/libcrit.so"
  assert_exit 3
  assert_contains "WARN javacritical  1 JavaCritical_ functions exported (1 library scanned)"
}

test_self_check_javacritical_clean_and_unreadable() {
  javacritical_fixtures
  self_check 1.8.0_512 "OpenJDK Runtime Environment Corretto-8.512.09.1 (build 1.8.0_512-b09)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$CASE_DIR/flags-cjn-true.txt"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/clean" "$CASE_DIR/jdk"
  assert_exit 0
  # an undefined (U) JavaCritical_ reference is not an export; nm -D --defined-only omits it
  assert_contains "PASS javacritical  no JavaCritical_ functions exported (2 libraries scanned, 1 not readable by nm)"
  mkdir -p "$CASE_DIR/empty"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/empty" "$CASE_DIR/jdk"
  assert_exit 0
  assert_contains "INFO javacritical  no *.so files found in the --native-libs paths"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/missing" "$CASE_DIR/jdk"
  assert_exit 2
  assert_contains "--native-libs: no such file or directory"
  run_script jdk-matrix/self-check.sh --native-libs
  assert_exit 2
  run_script jdk-matrix/self-check.sh "$CASE_DIR/jdk" "$CASE_DIR/jdk"
  assert_exit 2
  assert_contains "at most one JAVA_HOME is expected"
  assert_called "nm -D --defined-only $CASE_DIR/clean/libplain.so"
}

test_self_check_javacritical_not_affected() {
  javacritical_fixtures
  # Temurin 8 (CriticalJNINatives false by default): exported functions, no WARN
  self_check 1.8.0_504 "OpenJDK Runtime Environment (Temurin)(build 1.8.0_504-b01)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$CASE_DIR/flags-cjn-false.txt"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/app/lib" "$CASE_DIR/jdk"
  assert_exit 0
  assert_contains "PASS javacritical  2 JavaCritical_ functions exported (2 libraries scanned), but CriticalJNINatives=false in this JDK"
  # Corretto 8 on x86: INFO with the advice for Graviton
  self_check 1.8.0_512 "OpenJDK Runtime Environment Corretto-8.512.09.1 (build 1.8.0_512-b09)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$CASE_DIR/flags-cjn-true.txt"
  STUB_ENV+=(FAKE_ARCH=amd64)
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/app/lib" "$CASE_DIR/jdk"
  assert_exit 0
  assert_contains "INFO javacritical  2 JavaCritical_ functions exported (2 libraries scanned); with Corretto 8 on Graviton (AArch64) start the JVM with -XX:-CriticalJNINatives"
  # JDK 21 on AArch64 (no CriticalJNINatives flag): INFO, no WARN
  self_check 21.0.13 "OpenJDK Runtime Environment Corretto-21.0.13.11.1 (build 21.0.13+11-LTS)" \
    mountinfo-cgroup2.txt "always [madvise] never" "$FIXTURES/flags/host-a/corretto-21.0.13.0.11/printflagsfinal-r1.txt"
  run_script jdk-matrix/self-check.sh --native-libs "$CASE_DIR/app/lib" "$CASE_DIR/jdk"
  assert_exit 0
  assert_contains "INFO javacritical  2 JavaCritical_ functions exported"
  assert_not_contains "WARN"
}

# ---- jdk-matrix/run-sanity.sh -----------------------------------------------------------------
test_run_sanity_fake() {
  fake_jdk "$CASE_DIR/jdks/corretto-8.292.10.1" 1.8.0_292
  run_script jdk-matrix/run-sanity.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g --minutes 1
  assert_exit 0
  local d="$CASE_DIR/out/c9g/corretto-8.292.10.1"
  assert_file "$d/runs.jsonl"
  jq -e 'select(.run == "soak.log") | .exit_code == 0' "$d/runs.jsonl" >/dev/null || fail "soak run not recorded"
  [ ! -d "$d/hs_err" ] || fail "empty hs_err directory kept"
  run_script jdk-matrix/run-sanity.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g \
    --reproducer --repeats 2 --seconds 1
  assert_exit 0
  assert_file_exists "$d/jit-r2.json"
  assert_file_exists "$d/xint-r2.json"
  [ "$(grep -c '"run":"xint-r' "$d/runs.jsonl")" = 2 ] || fail "expected 2 -Xint runs"
  # a failing JVM is recorded and makes the exit code 1
  printf '#!/bin/bash\necho crash >&2\nexit 134\n' >"$CASE_DIR/jdks/corretto-8.292.10.1/bin/java"
  run_script jdk-matrix/run-sanity.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out3" --host-label c9g --minutes 1
  assert_exit 1
  assert_contains "exited with 134"
  run_script jdk-matrix/run-sanity.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/out" --host-label c9g --minutes 0
  assert_exit 2
}

# ---- Java programs (only with JAVA8_HOME) -------------------------------------------------------
java_homes() {
  [ -n "${JAVA8_HOME:-}" ] && printf '%s\n' "$JAVA8_HOME"
  [ -n "${JAVA21_HOME:-}" ] && printf '%s\n' "$JAVA21_HOME"
  return 0
}

test_java_compile_and_self_test() {
  [ -n "${JAVA8_HOME:-}" ] || return 77
  mkdir -p "$CASE_DIR/cg" "$CASE_DIR/jm"
  OUT="$CASE_DIR/javac.txt"
  "$JAVA8_HOME/bin/javac" -Xlint:all -Werror -XDignore.symbol.file -d "$CASE_DIR/cg" "$REPO_DIR"/cgroup-lab/java/*.java >"$OUT" 2>&1 ||
    fail "javac (cgroup-lab) failed"
  "$JAVA8_HOME/bin/javac" -Xlint:all -Werror -XDignore.symbol.file -d "$CASE_DIR/jm" "$REPO_DIR"/jdk-matrix/java/*.java >"$OUT" 2>&1 ||
    fail "javac (jdk-matrix) failed"
  local h c
  for h in $(java_homes); do
    for c in ContainerProbe AllocPressure ThreadFootprint; do
      OUT="$CASE_DIR/$c.json"
      "$h/bin/java" -cp "$CASE_DIR/cg" "$c" --self-test >"$OUT" 2>&1 || fail "$c --self-test failed on $h"
      jq -e -s 'length > 0 and any(.self_test == true)' "$OUT" >/dev/null || fail "$c output is not JSON with self_test"
    done
    for c in SanityWorkload UnsafeShiftCheck; do
      OUT="$CASE_DIR/$c.json"
      "$h/bin/java" -cp "$CASE_DIR/jm" "$c" --self-test >"$OUT" 2>&1 || fail "$c --self-test failed on $h"
      jq -e -s '.[-1] | .event == "summary" and .self_test == true' "$OUT" >/dev/null || fail "$c summary missing"
    done
    OUT="$CASE_DIR/usage.txt"
    if "$h/bin/java" -cp "$CASE_DIR/cg" ContainerProbe --bogus >"$OUT" 2>&1; then fail "ContainerProbe accepted --bogus"; fi
  done
}

test_java_run_matrix_real_jdks() {
  [ -n "${JAVA8_HOME:-}" ] || return 77
  mkdir -p "$CASE_DIR/jdks"
  ln -s "$JAVA8_HOME" "$CASE_DIR/jdks/corretto-8-local"
  if [ -n "${JAVA21_HOME:-}" ]; then ln -s "$JAVA21_HOME" "$CASE_DIR/jdks/corretto-21-local"; fi
  STUB_ENV=(PATH="$TEST_PATH")
  run_script jdk-matrix/run-matrix.sh --jdk-root "$CASE_DIR/jdks" --out "$CASE_DIR/m" --host-label local --repeats 2
  assert_exit 0
  assert_file_contains "$CASE_DIR/m/local/corretto-8-local/repeats.txt" "identical=yes"
  run_script jdk-matrix/flags-to-csv.sh --in "$CASE_DIR/m" --out-csv "$CASE_DIR/m.csv" --out-md "$CASE_DIR/m.md"
  assert_exit 0
  assert_file_contains "$CASE_DIR/m.csv" "local,corretto-8-local,UseSVE,,,false"
  assert_file_contains "$CASE_DIR/m.csv" "local,corretto-8-local,ThreadStackSize,"
  if [ -n "${JAVA21_HOME:-}" ]; then
    assert_file_contains "$CASE_DIR/m.csv" "local,corretto-21-local,ThreadStackSize,"
    assert_file_contains "$CASE_DIR/m.csv" ",default,true"
  fi
}

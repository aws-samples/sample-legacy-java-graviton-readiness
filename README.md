# Legacy JDK 8 readiness for AWS Graviton

[中文](README.zh-CN.md)

Many Java applications cannot move off JDK 8 quickly. Before such an application runs on
[AWS Graviton](https://aws.amazon.com/ec2/graviton/) processors, you need to know which JDK 8
patch level is the minimum that behaves correctly on Arm64 and in containers. This repository
contains the labs that measure it: they download exact builds of
[Amazon Corretto](https://aws.amazon.com/corretto/) and Eclipse Temurin, record what each build
detects and enables on AWS Graviton4 and Graviton5 hosts and on current x86 hosts (Intel and
AMD), and run the same JVMs in docker containers on Amazon Elastic Compute Cloud (Amazon EC2)
and in pods on Amazon Elastic Kubernetes Service (Amazon EKS) with Amazon Linux 2023 and
Bottlerocket nodes. It also contains `jdk-matrix/self-check.sh`, which checks a JDK you already
run against the measured thresholds. It is the lab companion of a blog post about the minimum
viable JDK 8 patch level on Graviton (link added on publication).

> **Note:** This is sample code, for non-production usage. You should work with your security and
> legal teams to meet your organizational security, regulatory and compliance requirements before
> deployment.

Contents:

- [What the labs measure](#what-the-labs-measure)
- [Measured minimum versions and settings](#measured-minimum-versions-and-settings)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [IAM permissions](#iam-permissions)
- [Quick start](#quick-start)
- [Script reference](#script-reference)
- [JDK catalog](#jdk-catalog)
- [Version thresholds in self-check.sh](#version-thresholds-in-self-checksh)
- [Costs](#costs)
- [Cleanup](#cleanup)
- [Security considerations](#security-considerations)
- [Limitations](#limitations)
- [Tested with](#tested-with)
- [Testing](#testing)
- [Third-party tools and licenses](#third-party-tools-and-licenses)
- [Planned modules](#planned-modules)

## What the labs measure

| Question | Lab | What is recorded |
|---|---|---|
| Does the JDK 8 AArch64 port matter (Corretto 8.282 with the IcedTea-based port, 8.292 with the port of OpenJDK 8u, and the latest 8)? | `jdk-matrix` | `-XX:+PrintFlagsFinal` defaults, `-XshowSettings`, a correctness soak, a reproducer for an AArch64 C2 addressing bug |
| Which intrinsics and atomics does each JDK enable on Graviton4, Graviton5 and x86? | `jdk-matrix` | A flag matrix (UseLSE, AES, GHASH, SHA, CRC32, SVE, ...) and the LSE instructions in `libjvm.so` |
| Which JDKs see the memory and CPU limits of a cgroup v2 container (JDK 8u362 and 8u372, 11.0.15 and 11.0.16, 17, 21)? | `cgroup-lab` | Detected memory and CPUs, maximum heap, GC and JIT threads, behavior under allocation pressure, OOM kills, on EC2 (docker) and EKS (Amazon Linux 2023, Bottlerocket) |
| How much memory do JVM threads take in a container on Graviton4 and Graviton5 compared with x86? | `cgroup-lab` | RSS, anonymous huge pages and NMT per thread count, `-Xss` value and transparent huge page mode |

The labs report defaults and behavior; they do not measure performance. Performance and
price-performance measurements are in the blog post (link added on publication).

## Measured minimum versions and settings

These results were measured on the platforms in [Tested with](#tested-with):
AWS Graviton4 (c8g, m8g), AWS Graviton5 (c9g, m9g), and Intel (c8i) and AMD (c8a) as the x86
comparison. All rows come from the labs in this repository, with two exceptions: the
`JavaCritical_` crash, which was measured with a JNI test library that is not part of this
repository (see the blog post), and the results marked †, which were measured with one-off
checks that are not part of this repository. Upstream sources for each threshold are in
[Version thresholds in self-check.sh](#version-thresholds-in-self-checksh).

Minimum JDK 8 patch levels:

| Where the JVM runs | Minimum | What the labs measured |
|---|---|---|
| Directly on a Graviton host | JDK 8u302, or Corretto 8.292.10.2 (fix for [JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689)) | `UnsafeShiftCheck` read wrong values in 5 of 5 JIT runs of Corretto 8.282.08.1 and 8.292.10.1 on c8g and c9g, and in 0 of 5 on Corretto 8.292.10.2, 8.372.07.1, 8.512.09.1 and Temurin 8u362 and 8u504. No wrong reads with `-Xint` or on c8i and c8a |
| In a container on a cgroup v2 host (Amazon Linux 2023, EKS Amazon Linux 2023 and Bottlerocket nodes) | JDK 8u372 (JDK 11: 11.0.16) | In a docker container with `--memory=1g --cpus=2` on c9g, Corretto 8.362 and Temurin 8u362 saw 8 CPUs and a maximum heap of 3910 MiB from the host and chose Parallel GC; Corretto 8.372 and 8.512 and Temurin 8u372 and 8u504 saw 2 CPUs and a 256 MiB heap and chose Serial GC. Under allocation pressure Corretto 8.362 and Temurin 8u362 were OOM-killed in 5 of 5 runs; Corretto 8.372, 8.512 and 21 stopped with `OutOfMemoryError` in 5 of 5. The same pattern on c8g, c8i and c8a, and in pods with 2 CPUs and 1 GiB on m8g and m9g nodes with Amazon Linux 2023 and Bottlerocket (there 8u362 saw the node's 4 CPUs and 3910 to 3920 MiB) |

Configuration items, for every JDK 8 patch:

| Item | Setting | What the labs measured |
|---|---|---|
| `MaxRAMPercentage` | Write `-XX:MaxRAMPercentage=75.0` on JDK 8, not `75` | JDK 8 stops with "Improperly specified VM option 'MaxRAMPercentage=75'" and exit code 1; `75.0` starts; JDK 21 accepts both †. With `75.0` in a 1 GiB container or pod, 8.372 and later get a 768 MiB maximum heap |
| Pods with a CPU request and no CPU limit | Set a CPU limit, or `-XX:ActiveProcessorCount` | With a CPU request of 1 and no CPU limit, every JDK saw all 4 vCPUs of the m8g or m9g node (`cpu.weight` 100); `-XX:ActiveProcessorCount=1` gave 1 CPU † |
| Serial GC in small containers | Name the GC explicitly if you need another one | With `--cpus=2`, a 1791 MiB memory limit gave Serial GC and 1792 MiB gave Parallel GC (8.372, 8.512) or G1 (JDK 21); `--cpus=1` gave Serial GC †. On JDK 8, Serial GC shows as `UseSerialGC`, `UseParallelGC` and `UseG1GC` all false in `-XX:+PrintFlagsFinal` |
| Native libraries that export `JavaCritical_` functions | With Corretto 8 on Graviton, add `-XX:-CriticalJNINatives` | Corretto 8.282, 8.362, 8.372 and 8.512 (c8g, c9g) and the Amazon Linux 2 RPM of Corretto 8.512 (c8g with Amazon Linux 2) exited with code 134 the first time they compiled a native method with a `JavaCritical_` entry point; with `-XX:-CriticalJNINatives` they ran without failures. Temurin 8 and Corretto 8.292.x have `CriticalJNINatives` false and were not affected. The libraries of the JDKs themselves export no such functions. Check your libraries with `self-check.sh --native-libs PATH` or `nm -D --defined-only LIB \| grep JavaCritical_` |

## Repository layout

```text
lib/                 common.sh (shared helpers), jdks.csv (JDK catalog), fetch-jdk.sh
jdk-matrix/          run-matrix.sh, flags-to-csv.sh, flags.txt, libjvm-lse.sh, run-sanity.sh,
                     self-check.sh, java/ (SanityWorkload, UnsafeShiftCheck)
cgroup-lab/          java/ (ContainerProbe, AllocPressure, ThreadFootprint),
                     configs-docker.csv, configs-eks.csv,
                     docker/ (run-docker-matrix.sh, run-thread-matrix.sh),
                     eks/ (eks-up.sh, run-eks-matrix.sh, eks-down.sh, cluster.yaml.tmpl,
                     namespace.yaml, nodeinfo-pod.yaml, example-job.yaml, pod scripts,
                     extract_jdk.py)
infra/               ec2-up.sh, ec2-exec.sh, collect.sh, cleanup.sh (EC2 test hosts)
tests/               run-tests.sh, cases-*.sh, stubs/, fixtures/ (offline tests)
```

The Java programs use Java 8 source level and JDK APIs only. Every lab script compiles them with
the javac of the JDK under test, so each JDK runs classes it compiled itself.

How a run fits together:

```text
 lib/jdks.csv --(fetch-jdk.sh: download, SHA-256 check, extract)--> <jdk-root>/<jdk-id>/
                                                                          |
   jdk-matrix/run-matrix.sh  ---- java -XX:+PrintFlagsFinal ... --------->|
   jdk-matrix/run-sanity.sh  ---- SanityWorkload, UnsafeShiftCheck ------>|
   cgroup-lab/docker/*.sh    ---- docker run (JDK bind-mounted read-only) |
   cgroup-lab/eks/*.sh       ---- Kubernetes Job (init container fetches  |
                                  the JDK and checks its SHA-256)         v
                                                                    results directory
 infra/ec2-up.sh -> infra/ec2-exec.sh (your run script) -> infra/collect.sh -> infra/cleanup.sh
```

## Prerequisites

- bash 3.2 or later, curl, tar, jq, and `sha256sum` or `shasum`. The scripts run on Linux and
  macOS; the docker labs need a Linux host.
- For the EC2 labs: AWS CLI v2 with credentials, a default VPC in the Region, and the Session
  Manager plugin if you want to open a shell on the hosts.
- For the docker labs on the host: docker, `timeout` (coreutils) and `journalctl`. Changing the
  transparent huge page (THP) mode needs root. `infra/ec2-up.sh` installs docker, binutils and jq
  on the hosts.
- For the EKS lab: eksctl, kubectl, and a Kubernetes version in EKS standard support.
- For `jdk-matrix/libjvm-lse.sh`: objdump and nm from binutils (on an AArch64 Linux host).

## IAM permissions

`infra/ec2-up.sh`: `sts:GetCallerIdentity`, `ssm:GetParameter` on the public
`/aws/service/ami-amazon-linux-latest/*` parameters, `ec2:DescribeInstanceTypes`,
`ec2:DescribeInstanceTypeOfferings`, `ec2:DescribeVpcs`, `ec2:DescribeSubnets`,
`ec2:CreateSecurityGroup`, `ec2:RunInstances`, `ec2:CreateTags`, `s3:CreateBucket`,
`s3:PutBucketTagging`, `s3:PutBucketPublicAccessBlock`, `s3:PutEncryptionConfiguration`,
`s3:PutBucketPolicy`, `s3:ListBucket` (for the existence check), `iam:GetRole`, `iam:CreateRole`,
`iam:TagRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:CreateInstanceProfile`,
`iam:TagInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:GetInstanceProfile` and
`iam:PassRole` on the lab role.

`infra/ec2-exec.sh`: `ec2:DescribeInstances`, `s3:PutObject` on the run's bucket and
`ssm:SendCommand` for the `AWS-RunShellScript` document and the lab instances.
`infra/collect.sh`: `s3:GetBucketTagging`, `s3:ListBucket` and `s3:GetObject` on the bucket.

`infra/cleanup.sh`: the `Describe*` and `List*` calls of the resources it checks
(`ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeSnapshots`, `ec2:DescribeImages`,
`ec2:DescribeSecurityGroups`, `ec2:DescribeKeyPairs`, `ec2:DescribeNatGateways`,
`ec2:DescribeAddresses`, `ec2:DescribeNetworkInterfaces`, `eks:ListClusters`, `eks:DescribeCluster`,
`cloudformation:ListStacks`, `iam:ListRoles`, `iam:GetRole`, `iam:GetInstanceProfile`,
`iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `s3:ListBucket`, `s3:GetBucketTagging`,
`tag:GetResources`), and for `--execute`: `ec2:TerminateInstances`, `ec2:DeleteVolume`,
`ec2:DeleteSecurityGroup`, `ec2:DeleteKeyPair`, `iam:RemoveRoleFromInstanceProfile`,
`iam:DeleteInstanceProfile`, `iam:DetachRolePolicy`, `iam:DeleteRolePolicy`, `iam:DeleteRole`,
`s3:DeleteObject`, `s3:DeleteBucket`, and what eksctl needs to delete a cluster.

The instance role that `ec2-up.sh` creates has the AWS managed policy
`AmazonSSMManagedInstanceCore` and an inline policy that allows only `s3:GetObject` and
`s3:PutObject` on the objects of the run's bucket and `s3:ListBucket` on that bucket.

`cgroup-lab/eks/eks-up.sh` uses eksctl, which creates IAM roles, a VPC and CloudFormation stacks;
see the [eksctl minimum IAM policies](https://eksctl.io/usage/minimum-iam-policies/).
`run-eks-matrix.sh` needs Kubernetes permissions to create namespaces, ConfigMaps, Jobs and Pods,
and to read pods, pod logs and nodes.

To confirm: these lists are derived from the API calls in the scripts; they were not tested with a
reduced policy.

## Quick start

The values below are placeholders. Scripts that create or delete billable resources print a plan
and ask you to type `yes` (or `DELETE`); `--yes` skips the prompt. Every script has `--help`.

```bash
# 0. Check a JDK you already run and the native libraries of your application
#    (no AWS calls, read-only)
./jdk-matrix/self-check.sh --native-libs /opt/example-app/lib /usr/lib/jvm/java-1.8.0-amazon-corretto

# 1. Download JDKs of the catalog on a host (checks SHA-256 before extracting)
./lib/fetch-jdk.sh --list
./lib/fetch-jdk.sh --id corretto-8.372.07.1 --dest ./jdks --cache ./cache

# 2. Create the EC2 test hosts (dry run first)
./infra/ec2-up.sh --region us-east-1 --owner example-owner --run-id run-20260101 \
  --types c8g.2xlarge,c9g.2xlarge,c8i.2xlarge,c8a.2xlarge --dry-run
./infra/ec2-up.sh --region us-east-1 --owner example-owner --run-id run-20260101 \
  --types c8g.2xlarge,c9g.2xlarge,c8i.2xlarge,c8a.2xlarge

# 3. Start your run script on a host; it calls the lab scripts and uploads results to
#    $JVMLAB_RESULTS (see "Writing a run script" below)
./infra/ec2-exec.sh --region us-east-1 --run-id run-20260101 \
  --instance-id i-0123456789abcdef0 --bundle ./bundle --script run.sh
./infra/collect.sh --region us-east-1 --run-id run-20260101 --dest ./results

# 4. EKS lab: create the cluster, run the Jobs on the m8g and the m9g nodes, delete the cluster
./cgroup-lab/eks/eks-up.sh --region us-east-1 --owner example-owner --run-id run-20260101 \
  --k8s-version 1.34 --api-allowed-cidr 203.0.113.10/32
./cgroup-lab/eks/run-eks-matrix.sh --instance-type m8g.xlarge \
  --jdks corretto-8.362.08.1,corretto-8.372.07.1 --out ./results/eks-m8g
./cgroup-lab/eks/run-eks-matrix.sh --instance-type m9g.xlarge \
  --jdks corretto-8.362.08.1,corretto-8.372.07.1 --out ./results/eks-m9g
./cgroup-lab/eks/eks-down.sh --region us-east-1 --run-id run-20260101 --execute

# 5. Delete everything of the run and verify
./infra/cleanup.sh --region us-east-1 --run-id run-20260101 --execute --verify
```

`--region` can be omitted when `AWS_REGION` is set. Use `--profile` to select an AWS CLI profile.

### Writing a run script

`infra/ec2-exec.sh` uploads a directory (the bundle) and runs one script from it on the instance
as root, in a transient systemd unit. A minimal run script for the bundle (this repository copied
to `./bundle/repo` plus `./bundle/run.sh`):

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
for id in corretto-8.362.08.1 corretto-8.372.07.1 corretto-21.0.13.0.11; do
  bash repo/lib/fetch-jdk.sh --id "$id" --dest /opt/jdks --cache /opt/cache \
    --log results/fetch-log.csv --host-label "$JVMLAB_HOST_LABEL"
done
bash repo/jdk-matrix/run-matrix.sh --jdk-root /opt/jdks --out results/flags \
  --host-label "$JVMLAB_HOST_LABEL" --libjvm-lse
bash repo/cgroup-lab/docker/run-docker-matrix.sh --jdk-root /opt/jdks --out results/cgroup \
  --host-label "$JVMLAB_HOST_LABEL"
aws s3 cp --recursive results "$JVMLAB_RESULTS" --region "$JVMLAB_REGION"
shutdown -h now   # the instance terminates itself
```

## Script reference

All scripts use `set -euo pipefail`, validate their input and exit with 0 on success, 1 on a
runtime error and 2 on a usage error, unless their help text says otherwise. AWS resources that
the scripts create carry the tags `project=sample-legacy-java-graviton-readiness`,
`owner=<--owner>` and `run-id=<--run-id>`.

### lib/fetch-jdk.sh

| Flag | Description |
|---|---|
| `--list` | Print the catalog |
| `--id` | Catalog ID, for example `corretto-8.372.07.1` |
| `--arch` | `aarch64`, `x64` or `auto` (default) |
| `--dest` | Directory that receives `<dest>/<id>` |
| `--cache` | Keep tarballs and reuse them when the checksum matches |
| `--log` | Append a CSV line per download (host, ID, URL, expected and actual SHA-256) |
| `--host-label` | Host column of the log line |

The SHA-256 is checked before anything is extracted. Tarballs with absolute or `..` member paths
are refused. A directory `<dest>/<id>` that holds a different build is never overwritten.

### jdk-matrix/run-matrix.sh

| Flag | Description |
|---|---|
| `--jdk-root`, `--out`, `--host-label` | JDK directory, result directory, host name in the results (required) |
| `--jdks` | Only these JDK IDs |
| `--repeats` | PrintFlagsFinal repeats, default 3; `repeats.txt` says whether they are identical |
| `--in-docker` | Also run PrintFlagsFinal with diagnostic flags unlocked in a container of this image without limits |
| `--libjvm-lse` | Also run `libjvm-lse.sh` |

### jdk-matrix/flags-to-csv.sh

| Flag | Description |
|---|---|
| `--in` | Result directory of `run-matrix.sh` |
| `--flags` | Flag list, default `jdk-matrix/flags.txt` |
| `--file` | File to read, default `printflagsfinal-diag.txt` (the run with `-XX:+UnlockDiagnosticVMOptions`) |
| `--out-csv`, `--out-md` | Long CSV (`host,jdk_id,flag,value,origin,present`) and a Markdown matrix per host |

A flag that a JDK does not have is `present=false` in the CSV and an em dash in Markdown, so
"absent" is never shown as `false`. The default input is the diagnostic-unlocked run because JDK
16 and later declare most intrinsic flags (for example `UseAESIntrinsics`, `UseSHA256Intrinsics`,
`UseCRC32Intrinsics`, `UseUnalignedAccesses`) as diagnostic, and plain `-XX:+PrintFlagsFinal`
does not print locked diagnostic flags. With `--file printflagsfinal-r1.txt` those flags show as
absent on JDK 17 and 21.

### jdk-matrix/libjvm-lse.sh

`libjvm-lse.sh JAVA_HOME` counts the LSE atomic instructions (`cas*`, `ldadd*`, `swp*`, ...), the
load-exclusive and store-exclusive instructions, and the `__aarch64_*` outline-atomics helpers in
`libjvm.so`. This shows whether the JVM's own C++ code uses LSE, which is separate from the
`UseLSE` flag (that flag controls the code generated by the JIT compilers).

### jdk-matrix/run-sanity.sh

| Flag | Description |
|---|---|
| `--jdk-root`, `--out`, `--host-label` | As above (required) |
| `--jdks` | Only these JDK IDs |
| `--minutes` | Soak duration per JDK, default 30 |
| `--reproducer` | Run `UnsafeShiftCheck` with the JIT and with `-Xint` instead of the soak |
| `--repeats`, `--seconds` | Reproducer runs per mode (default 5) and their duration (default 60 s) |

`SanityWorkload` checks AES/GCM, SHA-256, CRC32, BigInteger.modPow, regular expressions,
ConcurrentHashMap and AtomicLong under contention, and the checked `System.arraycopy` path against
known answers. `UnsafeShiftCheck` reads a byte array through `sun.misc.Unsafe` with addresses of
the form `base + (index << shift)` where the shift does not match the access size, the pattern of
[JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689), and compares every read with the
expected value. A run without mismatches or crashes is weak evidence of absence, not proof.

### jdk-matrix/self-check.sh

`self-check.sh [--native-libs PATH]... [JAVA_HOME]` prints PASS, WARN or INFO per check and the
JVM's own view (`-XshowSettings:system`). It exits with 3 when a check warns. The checks and their
sources are in [Version thresholds in self-check.sh](#version-thresholds-in-self-checksh). It only
reads; run it on the host or inside the container that runs your application.

`--native-libs` names a native library of your application, or a directory that is searched for
`*.so` and `*.so.*` files; repeat it for more paths. For each library the script runs
`nm -D --defined-only LIB | grep JavaCritical_`, the method of the lab, and lists the exported
`JavaCritical_` functions. It warns when it finds any and the JDK is JDK 8 on AArch64 with
`CriticalJNINatives` true. Libraries packed in JAR files must be extracted first. Without
`--native-libs`, or without `nm` (binutils), the check prints INFO and does not run.

### cgroup-lab/docker/run-docker-matrix.sh

| Flag | Description |
|---|---|
| `--jdk-root`, `--out`, `--host-label` | As above (required) |
| `--image` | Base image, default `public.ecr.aws/amazonlinux/amazonlinux:2023` pinned by digest |
| `--probe-src`, `--configs-file` | Probe sources and configuration table (defaults in `cgroup-lab/`) |
| `--configs`, `--jdks` | Only these configurations and JDK IDs |
| `--repeats`, `--alloc-repeats` | Repeats of probe (default 3) and allocation (default 5) configurations |
| `--cgroup-label` | `v1`, `v2` or `auto` (from `/proc/self/mountinfo`) |
| `--timeout` | Limit for one container run, default 900 s |
| `--dry-run` | Print the docker commands only |

Configurations (`cgroup-lab/configs-docker.csv`): D0 no limits; D1 `--memory=1g --cpus=1`; D2
`--memory=1g --cpus=2`; D3 `--memory=1g --cpuset-cpus=0-1`; D4 `--memory=1g --cpu-shares=512`; D5
D2 with `-Xmx512m`; D6 D2 with `-XX:MaxRAMPercentage=75.0`; A1 to A3 run `AllocPressure` under D2
without JVM flags, with `-XX:MaxRAMPercentage=75.0`, and with `-Xmx768m`. The A1 result of a JDK
without cgroup v2 support depends on host memory: its default heap is 1/4 of host memory, which
exceeds the 1 GiB limit on the 16 GiB hosts of [Tested with](#tested-with) (OOM kill), but fits
under it on a 4 GiB host, where 8u362 ends A1 with `OutOfMemoryError`; A2 and the EKS
configuration K6 show the OOM kill. JDK 8 accepts a double flag only with a
decimal point: `-XX:MaxRAMPercentage=75` stops JDK 8 with "Improperly specified VM option" and exit
code 1, while JDK 11 and later accept both forms. Each run also records the
JVM's container detection log (`-XX:+PrintContainerInfo` on JDK 8, `-Xlog:os+container=trace` on
JDK 11 and later) and `-XshowSettings:system`. Containers run with no network, a read-only root
file system, user 10001, no capabilities and the JDK mounted read-only. The JDK is bind-mounted
into one base image instead of building an image per JDK, so every JDK runs in the same user space.

### cgroup-lab/docker/run-thread-matrix.sh

| Flag | Description |
|---|---|
| `--jdk-root`, `--out`, `--host-label` | As above (required) |
| `--image`, `--probe-src`, `--jdks` | As above |
| `--thp-modes` | THP modes to test, default `never,madvise,always` |
| `--threads` | Thread counts, default `0,200,1000` |
| `--xss` | `default` or sizes such as `1m`, default `default,1m` |
| `--samples` | Sample times after all threads started, default `5,30` seconds |
| `--memory` | Container memory limit, default `4g` |
| `--repeats` | Repeats per cell, default 3 |
| `--oom-demo` | 1000 threads with THP `always` under a 1 GiB limit, 5 runs |
| `--timeout`, `--dry-run` | As above |

The script writes the THP mode to `/sys/kernel/mm/transparent_hugepage/enabled` for the runs and
restores the original mode on exit. NMT (`-XX:NativeMemoryTracking=summary`) is printed at JVM exit
next to RSS. jdk8u does not contain [JDK-8191369](https://bugs.openjdk.org/browse/JDK-8191369),
which made NMT report only the thread stack pages that are actually committed, so on JDK 8 read
NMT together with RSS, not alone.

### cgroup-lab/eks/eks-up.sh

| Flag | Description |
|---|---|
| `--region`, `--owner`, `--run-id`, `--k8s-version` | Required |
| `--cluster-name` | Default `jvm-cgroup-<run-id>` |
| `--api-allowed-cidr` | Restrict the public API endpoint to this CIDR |
| `--kubeconfig`, `--profile` | As usual |
| `--print-config` | Print the rendered ClusterConfig, no AWS calls |
| `--dry-run`, `--yes` | eksctl dry run; skip the confirmation |

The cluster has public subnets and no NAT gateway, and four managed node groups with one node
each: `al2023-m8g` and `br-m8g` on m8g.xlarge (AWS Graviton4), `al2023-m9g` and `br-m9g` on
m9g.xlarge (AWS Graviton5). The `al2023-*` groups run Amazon Linux 2023 and are labeled
`lab/os=al2023`, the `br-*` groups run Bottlerocket and are labeled `lab/os=bottlerocket`. Nodes
have no SSH access, IMDSv1 is disabled and volumes are encrypted. To use other arm64 instance
types, edit `instanceType` in `cluster.yaml.tmpl`.

### cgroup-lab/eks/run-eks-matrix.sh

| Flag | Description |
|---|---|
| `--instance-type` | Run on the nodes of this arm64 instance type, for example `m8g.xlarge` or `m9g.xlarge` (required) |
| `--jdks`, `--out` | JDK IDs (aarch64 builds of the catalog) and result directory (required); use one result directory per instance type |
| `--configs` | Only these configurations of `configs-eks.csv` |
| `--nodegroups` | `al2023`, `bottlerocket` or both (default) |
| `--repeats-probe`, `--repeats-alloc` | Repeats, default 3 and 5 |
| `--image`, `--timeout` | Container image; wait limit per Job, default 900 s |
| `--skip-nodeinfo` | Do not run the node information pods |
| `--print-job` | Print the Job manifest for `OS,JDK_ID,CONFIG` and exit (no cluster access) |

Configurations (`cgroup-lab/configs-eks.csv`): K1 requests and limits of 1 CPU and 1 GiB; K2 2
CPUs and 1 GiB; K3 a CPU request of 1 without a CPU limit and 1 GiB; K4 and K5 are K2 with
`-Xmx512m` and `-XX:MaxRAMPercentage=75.0`; K6 to K8 run `AllocPressure` under K2 without JVM flags,
with `-XX:MaxRAMPercentage=75.0` and with `-Xmx768m`. Each Job's init container downloads the JDK
over HTTPS, checks the SHA-256 of the catalog, extracts it with `extract_jdk.py` (the base image
has no tar) and compiles the probes. Pods run under the Pod Security Standard "restricted" profile.
Jobs and the node information pods select their node by `lab/os` and
`node.kubernetes.io/instance-type`, and carry the instance family in their names
(`jvmlab-<os>-<family>-<n>`, `nodeinfo-<os>-<family>`), so runs on m8g and m9g can share the
namespace. The node information pods record the kernel, cgroup file system type, THP settings,
page size and CPU features of each node group. `example-job.yaml` is one rendered Job.

### cgroup-lab/eks/eks-down.sh

`eks-down.sh --region REGION --run-id RUN_ID [--cluster-name NAME] [--execute [--yes]]` runs
`infra/cleanup.sh --eks-cluster NAME --verify`.

### infra/ec2-up.sh

| Flag | Description |
|---|---|
| `--region`, `--owner`, `--run-id`, `--types` | Required |
| `--groups` | Host groups; one instance per type and group, default `g1` |
| `--volume-gib` | Root volume, gp3, encrypted, default 50 |
| `--max-hours` | Shutdown timer in the user data, default 12; instances terminate when they shut down |
| `--resources-log` | Append a JSON line per created resource |
| `--profile`, `--dry-run`, `--yes` | As usual |

The script creates the S3 bucket `legacy-java-graviton-<run-id>` (Block Public Access, SSE-S3,
TLS-only bucket policy), the IAM role and instance profile `legacy-java-graviton-<run-id>-ec2`, a
security group without inbound rules in the default VPC, and the instances in the first
Availability Zone that offers all requested types. An instance for which that zone has no capacity
(`InsufficientInstanceCapacity`) is created in the next zone that offers all requested types; the
plan lists these fallback zones. Instances use the latest Amazon Linux 2023 AMI
from the public SSM parameter, require IMDSv2, have no key pair, and are named
`legacy-java-graviton-<run-id>-<family>-<group>` with the tag `lab-host=<family>-<group>`.

### infra/ec2-exec.sh

| Flag | Description |
|---|---|
| `--region`, `--run-id`, `--instance-id` | Instance of the run (its tags are checked) |
| `--bundle`, `--script` | Directory to upload and the script inside it to run |
| `--profile` | As usual |

### infra/collect.sh

`collect.sh --region REGION --run-id RUN_ID --dest DIR [--profile PROFILE]` runs `aws s3 sync`
from `results/` of the run's bucket after checking the bucket's tags.

### infra/cleanup.sh

| Flag | Description |
|---|---|
| `--region`, `--run-id` | Required |
| `--eks-cluster` | Also delete this EKS cluster with eksctl (it must carry the run's tags) |
| `--execute`, `--yes` | Delete; without `--execute` the script only prints the plan |
| `--verify`, `--verify-out` | List what still exists and exit with 1 if anything remains; write it as JSON |
| `--profile` | As usual |

## JDK catalog

`lib/jdks.csv` lists 27 tarballs (14 JDK IDs, aarch64 and x64; Corretto 8.292.10.2 exists for
aarch64 only) with their URL, the SHA-256 that `fetch-jdk.sh` checks, the vendor checksum and its
source:

| JDK ID | Why it is in the set |
|---|---|
| `corretto-8.282.08.1` | Last Corretto 8 with the IcedTea-based AArch64 port |
| `corretto-8.292.10.1` | First Corretto 8 with the AArch64 port of OpenJDK 8u |
| `corretto-8.292.10.2` | AArch64-only update of 8.292 with the fix for JDK-8267689 |
| `corretto-8.362.08.1`, `temurin-8u362-b09` | Last JDK 8 release before cgroup v2 support |
| `corretto-8.372.07.1`, `temurin-8u372-b07` | First JDK 8 release with cgroup v2 support |
| `corretto-8.512.09.1`, `temurin-8u504-b01` | Latest JDK 8 builds at the time of writing |
| `corretto-11.0.15.9.1`, `corretto-11.0.16.8.1` | JDK 11 before and with cgroup v2 support |
| `corretto-11.0.33.0.10`, `corretto-17.0.21.0.11`, `corretto-21.0.13.0.11` | Latest 11, 17 and 21 at the time of writing |

For Corretto 8.282.08.1, 8.292.10.1 and 8.292.10.2 the vendor published only MD5 checksums. For
these, the SHA-256 in the catalog was computed after the vendor MD5 and the GPG signature
(Corretto release key `A122542AB04F24E3`) were verified (`checksum_source` says so). All other
values are the SHA-256 published by the vendor.

## Version thresholds in self-check.sh

These thresholds come from the upstream sources below. The commit and tag facts were read from the
[openjdk/jdk8u](https://github.com/openjdk/jdk8u) repository. The last column is what was measured
on the platforms in [Tested with](#tested-with), with the labs in this repository, except for the
`JavaCritical_` crash (a JNI test library that is not part of this repository) and the results
marked †, which were measured with one-off checks that are not part of this repository.

| Check | Threshold | Source | Lab result |
|---|---|---|---|
| cgroup-v2 | JDK 8u372, 11.0.16, 15 | [JDK-8230305](https://bugs.openjdk.org/browse/JDK-8230305) "Cgroups v2: Container awareness"; in jdk8u first in tag `jdk8u372-b01`, not in `jdk8u362-b09` | Confirmed on cgroup v2 (EC2 docker on c8g, c9g, c8i and c8a; EKS Amazon Linux 2023 and Bottlerocket on m8g and m9g): 8u362 sized the heap from host memory, 8u372 from the 1 GiB limit; on c9g also 11.0.15 (host memory) and 11.0.16 (limit). On a c9g host booted into cgroup v1, 8u362 read the limits |
| container | JDK 8u191, 10 | [JDK-8146115](https://bugs.openjdk.org/browse/JDK-8146115) "Improve docker container detection and resource configuration usage" (adds `UseContainerSupport`), first in `jdk8u191-b02` | Not measured: every tested build is later than 8u191 |
| aarch64-port | JDK 8u292 | [JDK-8257192](https://bugs.openjdk.org/browse/JDK-8257192) "Integrate AArch64 JIT port into 8u", first in `jdk8u292-b01`; the [Corretto 8 change log](https://github.com/corretto/corretto-8/blob/develop/CHANGELOG.md) for 8.292.10.1 says the IcedTea-based port was replaced | No failure tied to the port switch itself: on c8g and c9g, Corretto 8.282.08.1 and 8.292.10.1 behaved the same in the reproducer and in a 30-minute soak |
| jdk-8267689 | JDK 8u302, Corretto 8.292.10.2 | [JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689), first in `jdk8u302-b05`; Corretto [pull request 303](https://github.com/corretto/corretto-8/pull/303) is the only HotSpot change between the tags 8.292.10.1 and 8.292.10.2 | Confirmed: the reproducer read wrong values in every JIT run of Corretto 8.282.08.1 and 8.292.10.1 on c8g and c9g; none on Corretto 8.292.10.2 and later, Temurin 8u362 and 8u504, with `-Xint` or on c8i and c8a |
| stack-thp | AArch64 `ThreadStackSize` 2048 with THP `always` | [JDK-8303215](https://bugs.openjdk.org/browse/JDK-8303215) "Make thread stacks not use huge pages", first in `jdk8u512-b01` | Depends on the kernel, therefore reported as INFO. Amazon Linux 2 (kernel 5.10) on c8g with THP `always`: Corretto 8.372 (2048 KB stacks) used 2038.7 to 2058.9 KiB per thread, 8.512 (2040 KB) 187.6 to 200.5 KiB; with THP `never` 149.7 to 152.1 KiB †. Amazon Linux 2023 (kernel 6.18, every thread stack mapped without huge pages †): THP `always` added 12.9 to 18.3 KiB per thread |
| javacritical | JDK 8 on AArch64 with `CriticalJNINatives` true: Corretto 8 (measured 8.282, 8.362, 8.372, 8.512); false in Temurin 8 and Corretto 8.292.x | Corretto 8 source: upstream jdk8u and Corretto up to 8.322.06.1 turn the flag off on aarch64 (`vm_version_aarch64.cpp`); that block is absent from Corretto 8.332.08.1 on, while the aarch64 helpers for critical natives in `sharedRuntime_aarch64.cpp` are still `Unimplemented()` in 8.512.09.1 | Confirmed on c8g and c9g, and with the Amazon Linux 2 RPM on c8g: exit code 134 with "Internal Error (sharedRuntime_aarch64.cpp:1045) Unimplemented()" (8.282: line 1035) when a method with a `JavaCritical_` entry point was compiled; no failures with `-XX:-CriticalJNINatives`; every JDK ran without failures on c8i. `nm` found 0 `JavaCritical_` functions in the 38 to 48 libraries of each tested JDK 8 |

A PASS means the JDK is past these thresholds, not that it is free of other defects.

## Costs

The labs create billable resources. Check current prices on the
[Amazon EC2](https://aws.amazon.com/ec2/pricing/on-demand/),
[Amazon EKS](https://aws.amazon.com/eks/pricing/),
[Amazon EBS](https://aws.amazon.com/ebs/pricing/),
[Amazon VPC](https://aws.amazon.com/vpc/pricing/) (public IPv4 addresses) and
[Amazon S3](https://aws.amazon.com/s3/pricing/) pricing pages. Estimate a run as:

- EC2: instance hours x on-demand price per type, plus EBS gp3 GiB-months for the root volumes
  (50 GiB each by default) and one public IPv4 address per instance per hour.
- EKS: control plane hours x the hourly cluster price, plus the four nodes (m8g.xlarge and
  m9g.xlarge instance hours, EBS and public IPv4). The test cluster has no NAT gateway.
- S3: small (bundles and results), plus data transfer out when you download the results.

Instances have a shutdown timer (`--max-hours`) and terminate when they shut down, so a forgotten
host does not run longer than that. Delete the EKS cluster as soon as its runs are done.

## Cleanup

1. `infra/cleanup.sh --region R --run-id ID` prints the plan: each resource is `delete`,
   `skip (not tagged for run ID)` or `absent`.
2. `--execute` deletes in this order: the EKS cluster (with `--eks-cluster`), instances (and waits
   until they are terminated), leftover available volumes, the security group, key pairs, the
   instance profile and role, and the bucket (objects first).
3. `--verify` lists everything of the run that still exists (instances that are not terminated,
   volumes, snapshots, AMIs, security groups, key pairs, NAT gateways, Elastic IPs, EKS clusters,
   CloudFormation stacks `eksctl-<cluster>-*`, IAM roles and the bucket, plus anything else the
   Resource Groups Tagging API reports with the run's tags) and exits with 1 if anything remains.
   The tagging API can list deleted resources for an hour or more. `--verify` checks the EC2
   instances, volumes and network interfaces it lists with `describe-*`, prints the ones that no
   longer exist (and terminated instances) as "listed by the tagging API but already deleted" and
   does not count them; for other resource types, run `--verify` again later.

Only resources with the tags `project=sample-legacy-java-graviton-readiness` and
`run-id=<run-id>` are deleted. Resources with the same names but without these tags are reported
and kept. The nodes, node volumes and security groups of the EKS cluster carry the run's tags too;
they are reported as part of the cluster and kept, and eksctl deletes them with the cluster.

## Security considerations

- The EC2 hosts have no inbound security group rules and no key pair; access is through Session
  Manager. IMDSv2 is required and root volumes are encrypted.
- The S3 bucket blocks public access, uses SSE-S3 and denies requests without TLS. The instance
  role can only read and write objects of this bucket, plus the Session Manager permissions of
  `AmazonSSMManagedInstanceCore`.
- JDK downloads use HTTPS only, and every tarball is checked against a pinned SHA-256 before it is
  extracted. The container image is pinned by digest.
- Containers run as a non-root user with no capabilities, no privilege escalation, a read-only
  root file system and (docker) no network. EKS pods run under the "restricted" Pod Security
  Standard and do not mount a service account token.
- `run-thread-matrix.sh` changes the host's THP mode while it runs (it restores it on exit). Run
  it only on dedicated test hosts.
- Without `--api-allowed-cidr`, the EKS public API endpoint accepts requests from all addresses
  (requests still need valid credentials).
- eksctl creates the IAM roles of the EKS cluster and the node groups and their security groups
  with its defaults; see the [eksctl documentation](https://eksctl.io/usage/minimum-iam-policies/).
- Use a sandbox account and least-privilege roles (see [IAM permissions](#iam-permissions)).

## Limitations

- Commercial AWS partition only; the scripts refuse Regions in China, AWS GovCloud (US) and the
  AWS European Sovereign Cloud.
- The docker labs need a Linux host with docker; the EKS lab uses arm64 nodes only. x86 references
  come from the EC2 labs.
- The measurements cover AWS Graviton4 and Graviton5. The scripts run on any arm64 generation, but
  results on earlier generations are not part of this repository.
- The EKS user guide does not state Bottlerocket support for Graviton5. Bottlerocket nodes on
  m9g.xlarge became Ready and ran every pod of the lab; this is an observation, not a support
  statement.
- `self-check.sh --native-libs` reads only the files you give it. It does not find libraries that
  an application extracts from JAR files at run time.
- The labs record JVM defaults and container behavior. They do not measure performance.
- The JDK catalog is a fixed list. Other vendors and builds are not covered; add rows with their
  vendor SHA-256 to test them.
- `self-check.sh` checks the thresholds in the table above only.

## Tested with

The scripts were run in us-east-1 with these versions:

| Component | Version |
|---|---|
| EC2 instance types | c8g.2xlarge (AWS Graviton4), c9g.2xlarge (AWS Graviton5), c8i.2xlarge (Intel Xeon 6975P-C) and c8a.2xlarge (AMD EPYC 9R45) as the x86 comparison; 8 vCPUs and 16 GiB each |
| EC2 AMI | Amazon Linux 2023 AMI from the SSM parameters `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` and `-x86_64` (Amazon Linux 2023.12.20261102, kernel 6.18.56-125.164.amzn2023); for the THP and RPM checks also one c8g.2xlarge with Amazon Linux 2 (2.0.20261102.0, kernel 5.10.271-272.1121.amzn2) |
| Host settings | cgroup v2 (`cgroup2fs`), THP `madvise` by default, 4 KiB pages; cgroup v1 control on c9g with `systemd.unified_cgroup_hierarchy=0` |
| Container runtime on EC2 | Docker 25.0.18, containerd 2.3.7, runc 1.4.3 |
| Container image | `public.ecr.aws/amazonlinux/amazonlinux:2023` at the digest pinned in `lib/common.sh` |
| Amazon EKS | Kubernetes 1.37, eksctl 0.231.0-dev, kubectl 1.35.0; node groups `al2023-m8g`, `br-m8g` (m8g.xlarge) and `al2023-m9g`, `br-m9g` (m9g.xlarge) with the settings of `cluster.yaml.tmpl`, added with `eksctl create nodegroup` to a cluster created by `eks-up.sh` |
| EKS node groups | Amazon Linux 2023 node group release 1.37.1-20261107 (containerd 2.3.7); Bottlerocket 1.68.1 `aws-k8s-1.37` (containerd 2.3.6); all kernel 6.18.56, cgroup v2, THP `madvise`, 4 vCPUs |
| JDKs | All 14 IDs in `lib/jdks.csv` (aarch64 builds on c8g and c9g, x64 builds on c8i and c8a; `corretto-8.292.10.2` has no x64 build), and the Amazon Linux 2 RPM `java-1.8.0-amazon-corretto-devel-1.8.0_512.b09-1.amzn2` |

## Testing

The tests run offline. `tests/run-tests.sh` replaces `aws`, `eksctl`, `kubectl`, `docker`,
`journalctl`, `objdump`, `nm`, `timeout` and `uname` with stubs in `tests/stubs`, creates fake JDK
launchers in a temporary directory, and runs each script there. No AWS credentials or network
access are used.

```bash
bash tests/run-tests.sh
# also compile the Java programs with -Xlint:all -Werror and run their self-tests:
JAVA8_HOME=/path/to/jdk8 JAVA21_HOME=/path/to/jdk21 bash tests/run-tests.sh
```

The tests check argument validation, dry-run output, confirmation handling, checksum verification,
the flag parser on JDK 8, 11 and 21 output formats, the self-check thresholds and its
`JavaCritical_` check (with fake libraries and an `nm` stub), the docker and
Kubernetes command lines, tag checks and the cleanup order. They need bash 3.2 or later, jq and
python3.

## Third-party tools and licenses

This repository contains only the scripts, programs and documents in it. It does not include or
redistribute any JDK or tool; the scripts download JDKs at run time, and you install the tools.

| Software | License | How it is used |
|---|---|---|
| Amazon Corretto, Eclipse Temurin (JDK builds) | GPL-2.0 with Classpath Exception | Downloaded at run time by `fetch-jdk.sh` and the EKS init container |
| Amazon Linux 2023 container image | See the image | Pulled at run time as the base image |
| AWS CLI v2, kubectl, eksctl | Apache-2.0 | Installed by you |
| jq | MIT | Installed by you |
| docker | Apache-2.0 | Installed by you or by `ec2-up.sh` on the hosts |
| bash, curl, tar, coreutils, binutils, Python 3 | GPL-3.0 (bash, coreutils, binutils, tar), curl license, PSF-2.0 | Installed by you or with the operating system |

The blog post also used jcstress and JMH (GPL-2.0 with Classpath Exception) for its memory model
and microbenchmark measurements. Neither they nor tests or benchmarks built with them are part of
this repository.

## Planned modules

A Java Memory Model lab (data races under the Arm memory model compared with x86) may be added after
license review.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

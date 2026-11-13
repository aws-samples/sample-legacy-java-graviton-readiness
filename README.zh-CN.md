# 旧版 JDK 8 应用迁移 AWS Graviton 的就绪性验证

[English](README.md)

许多 Java 应用无法在短期内升级到 JDK 8 以上版本。在这类应用运行到
[AWS Graviton](https://aws.amazon.com/ec2/graviton/) 处理器之前，需要先确定：在 Arm64 架构和容器环境中行为正确的
JDK 8 最低补丁版本是哪一个。本仓库提供用于测量这一问题的实验：下载
[Amazon Corretto](https://aws.amazon.com/corretto/) 与 Eclipse Temurin 的指定构建，记录每个构建在 AWS Graviton4、
Graviton5 主机和当前 x86（Intel 与 AMD）主机上检测到和启用的功能，并在 Amazon Elastic Compute Cloud（Amazon EC2）的
docker 容器中，以及 Amazon Elastic Kubernetes Service（Amazon EKS）的 Amazon Linux 2023 与 Bottlerocket 节点上的 Pod
中运行相同的 JVM。仓库中的 `jdk-matrix/self-check.sh` 可以按实测门槛检查您正在使用的 JDK。本仓库是一篇博客文章的配套实验，
该文章讨论 Graviton 上 JDK 8 的最低可行补丁版本（文章发布后补充链接）。

> **注意：** This is sample code, for non-production usage. You should work with your security and
> legal teams to meet your organizational security, regulatory and compliance requirements before
> deployment.（本示例代码仅供非生产环境使用。部署前，请与您的安全和法务团队合作，满足组织的安全、监管与合规要求。）

目录：

- [实验测量的内容](#实验测量的内容)
- [实测的最低版本与配置](#实测的最低版本与配置)
- [仓库结构](#仓库结构)
- [前提条件](#前提条件)
- [IAM 权限](#iam-权限)
- [快速开始](#快速开始)
- [脚本参考](#脚本参考)
- [JDK 清单](#jdk-清单)
- [self-check.sh 使用的版本阈值](#self-checksh-使用的版本阈值)
- [费用](#费用)
- [清理](#清理)
- [安全注意事项](#安全注意事项)
- [限制](#限制)
- [测试环境](#测试环境)
- [测试](#测试)
- [第三方工具与许可证](#第三方工具与许可证)
- [计划中的模块](#计划中的模块)

## 实验测量的内容

| 问题 | 实验 | 记录内容 |
|---|---|---|
| JDK 8 的 AArch64 移植来源是否有影响（采用基于 IcedTea 移植的 Corretto 8.282、采用 OpenJDK 8u 移植的 8.292，以及最新的 8）？ | `jdk-matrix` | `-XX:+PrintFlagsFinal` 默认值、`-XshowSettings`、正确性长时间运行测试、一个 AArch64 C2 寻址缺陷的复现程序 |
| 各 JDK 在 Graviton4、Graviton5 和 x86 上分别启用了哪些 intrinsic 和原子指令？ | `jdk-matrix` | 标志矩阵（UseLSE、AES、GHASH、SHA、CRC32、SVE 等）以及 `libjvm.so` 中的 LSE 指令 |
| 哪些 JDK 能识别 cgroup v2 容器的内存和 CPU 限制（JDK 8u362 与 8u372、11.0.15 与 11.0.16、17、21）？ | `cgroup-lab` | 检测到的内存与 CPU 数、最大堆、GC 与 JIT 线程数、内存分配压力下的行为、OOM 终止情况；环境为 EC2（docker）和 EKS（Amazon Linux 2023、Bottlerocket） |
| 与 x86 相比，Graviton4 和 Graviton5 容器中 JVM 线程占用多少内存？ | `cgroup-lab` | 按线程数、`-Xss` 取值和透明大页模式记录的 RSS、匿名大页和 NMT |

实验只记录默认值和行为，不测量性能。性能与性价比的测量结果见博客文章（文章发布后补充链接）。

## 实测的最低版本与配置

以下结果在[测试环境](#测试环境)所列平台上测得：AWS Graviton4（c8g、m8g）、AWS Graviton5（c9g、m9g），
以及作为 x86 对照的 Intel（c8i）和 AMD（c8a）。各行都来自本仓库中的实验，但有两类例外：`JavaCritical_` 崩溃是用
一个不在本仓库中的 JNI 测试库测得的（见博客文章）；标有 † 的结果是用不在本仓库中的一次性检查测得的。各门槛的上游来源见 [self-check.sh 使用的版本阈值](#self-checksh-使用的版本阈值)。

JDK 8 最低补丁版本：

| JVM 运行位置 | 最低版本 | 实验测得的结果 |
|---|---|---|
| 直接运行在 Graviton 主机上 | JDK 8u302，或 Corretto 8.292.10.2（包含 [JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689) 的修复） | 在 c8g 和 c9g 上，`UnsafeShiftCheck` 在 Corretto 8.282.08.1 和 8.292.10.1 的 JIT 运行中 5 次有 5 次读到错误值；在 Corretto 8.292.10.2、8.372.07.1、8.512.09.1 以及 Temurin 8u362、8u504 上 5 次均为 0。`-Xint` 下以及 c8i、c8a 上都没有读错 |
| cgroup v2 主机上的容器中（Amazon Linux 2023、EKS 的 Amazon Linux 2023 与 Bottlerocket 节点） | JDK 8u372（JDK 11 为 11.0.16） | 在 c9g 上 `--memory=1g --cpus=2` 的 docker 容器中，Corretto 8.362 和 Temurin 8u362 看到宿主机的 8 个 CPU 和 3910 MiB 最大堆，选用 Parallel GC；Corretto 8.372、8.512 和 Temurin 8u372、8u504 看到 2 个 CPU 和 256 MiB 最大堆，选用 Serial GC。内存分配压力下，Corretto 8.362 和 Temurin 8u362 5 次有 5 次被 OOM kill；Corretto 8.372、8.512 和 21 5 次均以 `OutOfMemoryError` 结束。c8g、c8i、c8a 上，以及 m8g、m9g 节点（Amazon Linux 2023 与 Bottlerocket）上 2 个 CPU、1 GiB 的 Pod 中结果模式相同（Pod 中 8u362 看到节点的 4 个 CPU 和 3910 至 3920 MiB） |

配置项（适用于所有 JDK 8 补丁）：

| 项目 | 设置 | 实验测得的结果 |
|---|---|---|
| `MaxRAMPercentage` | JDK 8 上写 `-XX:MaxRAMPercentage=75.0`，不要写 `75` | JDK 8 报"Improperly specified VM option 'MaxRAMPercentage=75'"并以退出码 1 结束；`75.0` 可以启动；JDK 21 两种写法都接受 †。在 1 GiB 的容器或 Pod 中使用 `75.0` 时，8.372 及以后的最大堆为 768 MiB |
| 只设 CPU request、不设 CPU limit 的 Pod | 设置 CPU limit，或使用 `-XX:ActiveProcessorCount` | CPU request 为 1、不设 CPU limit 时，所有 JDK 都看到 m8g 或 m9g 节点的全部 4 个 vCPU（`cpu.weight` 为 100）；`-XX:ActiveProcessorCount=1` 时为 1 个 CPU † |
| 小容器默认使用 Serial GC | 需要其他 GC 时显式指定 | `--cpus=2` 时，内存限制 1791 MiB 选用 Serial GC，1792 MiB 选用 Parallel GC（8.372、8.512）或 G1（JDK 21）；`--cpus=1` 时选用 Serial GC †。JDK 8 使用 Serial GC 时，`-XX:+PrintFlagsFinal` 中 `UseSerialGC`、`UseParallelGC`、`UseG1GC` 三个标志都为 false |
| 导出 `JavaCritical_` 函数的本地库 | Graviton 上的 Corretto 8 加 `-XX:-CriticalJNINatives` | Corretto 8.282、8.362、8.372、8.512（c8g、c9g）以及 Corretto 8.512 的 Amazon Linux 2 RPM（运行 Amazon Linux 2 的 c8g）在第一次编译带 `JavaCritical_` 入口的本地方法时以退出码 134 结束；加 `-XX:-CriticalJNINatives` 后运行无故障。Temurin 8 和 Corretto 8.292.x 的 `CriticalJNINatives` 为 false，不受影响。JDK 自带的本地库没有导出这类函数。可用 `self-check.sh --native-libs PATH` 或 `nm -D --defined-only LIB \| grep JavaCritical_` 检查自己的库 |

## 仓库结构

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

Java 程序使用 Java 8 源码级别，只依赖 JDK 自带 API。每个实验脚本都用被测 JDK 自己的 javac 编译这些程序，因此每个 JDK
运行的都是由它自己编译的类。

一次运行的整体流程：

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

## 前提条件

- bash 3.2 或更高版本、curl、tar、jq，以及 `sha256sum` 或 `shasum`。脚本可在 Linux 和 macOS 上运行；docker 实验需要
  Linux 主机。
- EC2 实验：已配置凭证的 AWS CLI v2、所在区域的默认 VPC；如需在主机上打开 shell，还需要 Session Manager 插件。
- 在主机上运行 docker 实验：docker、`timeout`（coreutils）和 `journalctl`。修改透明大页（THP）模式需要 root 权限。
  `infra/ec2-up.sh` 会在主机上安装 docker、binutils 和 jq。
- EKS 实验：eksctl、kubectl，以及处于 EKS 标准支持期内的 Kubernetes 版本。
- `jdk-matrix/libjvm-lse.sh`：binutils 中的 objdump 和 nm（在 AArch64 Linux 主机上运行）。

## IAM 权限

`infra/ec2-up.sh`：`sts:GetCallerIdentity`、对公共参数 `/aws/service/ami-amazon-linux-latest/*` 的
`ssm:GetParameter`、`ec2:DescribeInstanceTypes`、`ec2:DescribeInstanceTypeOfferings`、`ec2:DescribeVpcs`、
`ec2:DescribeSubnets`、`ec2:CreateSecurityGroup`、`ec2:RunInstances`、`ec2:CreateTags`、`s3:CreateBucket`、
`s3:PutBucketTagging`、`s3:PutBucketPublicAccessBlock`、`s3:PutEncryptionConfiguration`、`s3:PutBucketPolicy`、
`s3:ListBucket`（用于存在性检查）、`iam:GetRole`、`iam:CreateRole`、`iam:TagRole`、`iam:AttachRolePolicy`、
`iam:PutRolePolicy`、`iam:CreateInstanceProfile`、`iam:TagInstanceProfile`、`iam:AddRoleToInstanceProfile`、
`iam:GetInstanceProfile`，以及对实验角色的 `iam:PassRole`。

`infra/ec2-exec.sh`：`ec2:DescribeInstances`、对本次运行存储桶的 `s3:PutObject`，以及对 `AWS-RunShellScript`
文档和实验实例的 `ssm:SendCommand`。`infra/collect.sh`：对该存储桶的 `s3:GetBucketTagging`、`s3:ListBucket` 和
`s3:GetObject`。

`infra/cleanup.sh`：检查各类资源所需的 `Describe*` 和 `List*` 调用（`ec2:DescribeInstances`、`ec2:DescribeVolumes`、
`ec2:DescribeSnapshots`、`ec2:DescribeImages`、`ec2:DescribeSecurityGroups`、`ec2:DescribeKeyPairs`、
`ec2:DescribeNatGateways`、`ec2:DescribeAddresses`、`ec2:DescribeNetworkInterfaces`、`eks:ListClusters`、`eks:DescribeCluster`、
`cloudformation:ListStacks`、`iam:ListRoles`、`iam:GetRole`、`iam:GetInstanceProfile`、
`iam:ListAttachedRolePolicies`、`iam:ListRolePolicies`、`s3:ListBucket`、`s3:GetBucketTagging`、
`tag:GetResources`）；使用 `--execute` 时还需要 `ec2:TerminateInstances`、`ec2:DeleteVolume`、
`ec2:DeleteSecurityGroup`、`ec2:DeleteKeyPair`、`iam:RemoveRoleFromInstanceProfile`、`iam:DeleteInstanceProfile`、
`iam:DetachRolePolicy`、`iam:DeleteRolePolicy`、`iam:DeleteRole`、`s3:DeleteObject`、`s3:DeleteBucket`，以及 eksctl
删除集群所需的权限。

`ec2-up.sh` 创建的实例角色附加了 AWS 托管策略 `AmazonSSMManagedInstanceCore`，以及一条内联策略：只允许对本次运行存储桶中的对象执行
`s3:GetObject` 和 `s3:PutObject`，并允许对该存储桶执行 `s3:ListBucket`。

`cgroup-lab/eks/eks-up.sh` 使用 eksctl，eksctl 会创建 IAM 角色、VPC 和 CloudFormation 堆栈，参见
[eksctl 最小 IAM 策略](https://eksctl.io/usage/minimum-iam-policies/)。`run-eks-matrix.sh` 需要 Kubernetes 权限：创建
Namespace、ConfigMap、Job 和 Pod，读取 Pod、Pod 日志和节点。

待确认：以上列表根据脚本中的 API 调用整理，尚未用最小化策略实测。

## 快速开始

下面的取值均为占位符。创建或删除计费资源的脚本会先打印计划，并要求输入 `yes`（或 `DELETE`）确认；`--yes` 可跳过确认。
每个脚本都支持 `--help`。

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

设置了 `AWS_REGION` 时可以省略 `--region`。使用 `--profile` 指定 AWS CLI 配置文件。

### 编写运行脚本

`infra/ec2-exec.sh` 上传一个目录（bundle），并在实例上以 root 身份、在临时 systemd 单元中运行其中的一个脚本。以下是一个最小的运行脚本示例
（bundle 由复制到 `./bundle/repo` 的本仓库和 `./bundle/run.sh` 组成）：

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

## 脚本参考

所有脚本都使用 `set -euo pipefail` 并校验输入；除帮助文本另有说明外，成功时退出码为 0，运行时错误为 1，用法错误为 2。
脚本创建的 AWS 资源都带有标签 `project=sample-legacy-java-graviton-readiness`、`owner=<--owner>` 和
`run-id=<--run-id>`。

### lib/fetch-jdk.sh

| 参数 | 说明 |
|---|---|
| `--list` | 打印清单 |
| `--id` | 清单 ID，例如 `corretto-8.372.07.1` |
| `--arch` | `aarch64`、`x64` 或 `auto`（默认） |
| `--dest` | 存放 `<dest>/<id>` 的目录 |
| `--cache` | 保留下载的压缩包，校验和一致时复用 |
| `--log` | 每次下载追加一行 CSV（主机、ID、URL、期望与实际 SHA-256） |
| `--host-label` | 日志行中的主机列 |

解压任何内容之前都会先校验 SHA-256。成员路径为绝对路径或包含 `..` 的压缩包会被拒绝。如果 `<dest>/<id>` 中已有另一个构建，
脚本不会覆盖它。

### jdk-matrix/run-matrix.sh

| 参数 | 说明 |
|---|---|
| `--jdk-root`、`--out`、`--host-label` | JDK 目录、结果目录、结果中的主机名（必填） |
| `--jdks` | 只运行这些 JDK ID |
| `--repeats` | PrintFlagsFinal 重复次数，默认 3；`repeats.txt` 记录各次输出是否一致 |
| `--in-docker` | 另外在该镜像的无限制容器中运行解锁诊断标志的 PrintFlagsFinal |
| `--libjvm-lse` | 另外运行 `libjvm-lse.sh` |

### jdk-matrix/flags-to-csv.sh

| 参数 | 说明 |
|---|---|
| `--in` | `run-matrix.sh` 的结果目录 |
| `--flags` | 标志列表，默认 `jdk-matrix/flags.txt` |
| `--file` | 读取的文件，默认 `printflagsfinal-diag.txt`（使用 `-XX:+UnlockDiagnosticVMOptions` 的那次运行） |
| `--out-csv`、`--out-md` | 长格式 CSV（`host,jdk_id,flag,value,origin,present`）和按主机划分的 Markdown 矩阵 |

某个 JDK 不存在的标志在 CSV 中为 `present=false`，在 Markdown 中显示为破折号，因此"不存在"不会被显示成 `false`。
默认读取解锁诊断标志的输出，原因是 JDK 16 及以后版本把大部分 intrinsic 标志（例如 `UseAESIntrinsics`、`UseSHA256Intrinsics`、
`UseCRC32Intrinsics`、`UseUnalignedAccesses`）声明为诊断标志，而普通的 `-XX:+PrintFlagsFinal` 不会打印未解锁的诊断标志。
如果指定 `--file printflagsfinal-r1.txt`，这些标志在 JDK 17 和 21 上会显示为不存在。

### jdk-matrix/libjvm-lse.sh

`libjvm-lse.sh JAVA_HOME` 统计 `libjvm.so` 中的 LSE 原子指令（`cas*`、`ldadd*`、`swp*` 等）、独占加载与独占存储指令，以及
`__aarch64_*` outline-atomics 辅助函数。由此可以看出 JVM 自身的 C++ 代码是否使用 LSE；这与 `UseLSE` 标志无关
（该标志控制的是 JIT 编译器生成的代码）。

### jdk-matrix/run-sanity.sh

| 参数 | 说明 |
|---|---|
| `--jdk-root`、`--out`、`--host-label` | 同上（必填） |
| `--jdks` | 只运行这些 JDK ID |
| `--minutes` | 每个 JDK 的长时间运行时长，默认 30 分钟 |
| `--reproducer` | 改为运行 `UnsafeShiftCheck`（分别在启用 JIT 和 `-Xint` 下运行） |
| `--repeats`、`--seconds` | 复现程序在每种模式下的运行次数（默认 5）和每次时长（默认 60 秒） |

`SanityWorkload` 用已知结果校验 AES/GCM、SHA-256、CRC32、BigInteger.modPow、正则表达式、竞争下的 ConcurrentHashMap 与
AtomicLong，以及带类型检查的 `System.arraycopy` 路径。`UnsafeShiftCheck` 通过 `sun.misc.Unsafe` 以
`base + (index << shift)` 形式的地址读取字节数组，其中移位量与访问宽度不匹配，这正是
[JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689) 的模式；程序将每次读取与期望值比较。一次运行未出现不一致或崩溃，
只是"未观察到"的弱证据，并不能证明缺陷不存在。

### jdk-matrix/self-check.sh

`self-check.sh [--native-libs PATH]... [JAVA_HOME]` 对每项检查输出 PASS、WARN 或 INFO，并打印 JVM 自身的视角
（`-XshowSettings:system`）。任一检查为 WARN 时退出码为 3。各项检查及其来源见
[self-check.sh 使用的版本阈值](#self-checksh-使用的版本阈值)。该脚本只读取信息；请在运行应用的主机或容器内运行它。

`--native-libs` 指定应用的一个本地库，或一个目录（脚本在其中查找 `*.so` 和 `*.so.*` 文件）；可重复指定多个路径。脚本对每个库
运行实验中使用的方法 `nm -D --defined-only LIB | grep JavaCritical_`，并列出导出的 `JavaCritical_` 函数。找到这类函数、且
JDK 是 AArch64 上 `CriticalJNINatives` 为 true 的 JDK 8 时输出 WARN。打包在 JAR 文件中的库需要先解压。不指定
`--native-libs` 或没有 `nm`（binutils）时，这项检查只输出 INFO，不运行。

### cgroup-lab/docker/run-docker-matrix.sh

| 参数 | 说明 |
|---|---|
| `--jdk-root`、`--out`、`--host-label` | 同上（必填） |
| `--image` | 基础镜像，默认为按摘要固定的 `public.ecr.aws/amazonlinux/amazonlinux:2023` |
| `--probe-src`、`--configs-file` | 探测程序源码与配置表（默认位于 `cgroup-lab/`） |
| `--configs`、`--jdks` | 只运行这些配置和 JDK ID |
| `--repeats`、`--alloc-repeats` | 探测配置（默认 3 次）和内存分配配置（默认 5 次）的重复次数 |
| `--cgroup-label` | `v1`、`v2` 或 `auto`（根据 `/proc/self/mountinfo` 判断） |
| `--timeout` | 单次容器运行的时限，默认 900 秒 |
| `--dry-run` | 只打印 docker 命令 |

配置（`cgroup-lab/configs-docker.csv`）：D0 无限制；D1 `--memory=1g --cpus=1`；D2 `--memory=1g --cpus=2`；D3
`--memory=1g --cpuset-cpus=0-1`；D4 `--memory=1g --cpu-shares=512`；D5 为 D2 加 `-Xmx512m`；D6 为 D2 加
`-XX:MaxRAMPercentage=75.0`；A1 至 A3 在 D2 下运行 `AllocPressure`，分别不加 JVM 标志、加 `-XX:MaxRAMPercentage=75.0`、加
`-Xmx768m`。不支持 cgroup v2 的 JDK 在 A1 中的结果取决于宿主机内存：其默认堆为宿主机内存的 1/4，在
[测试环境](#测试环境)中 16 GiB 的宿主机上超过 1 GiB 限制（被 OOM 终止），在 4 GiB 的宿主机上则低于该限制，8u362 在 A1 中以
`OutOfMemoryError` 结束；A2 和 EKS 配置 K6 展示了 OOM 终止。JDK 8 只接受带小数点的浮点型标志值：`-XX:MaxRAMPercentage=75` 会让 JDK 8 报"Improperly specified VM option"
并以退出码 1 结束，JDK 11 及以后两种写法都接受。每次运行还会记录 JVM 的容器检测日志（JDK 8 使用 `-XX:+PrintContainerInfo`，JDK 11 及以后使用
`-Xlog:os+container=trace`）和 `-XshowSettings:system` 的输出。容器在无网络、根文件系统只读、用户 10001、不授予任何
capability 的条件下运行，JDK 以只读方式挂载。JDK 通过 bind mount 挂载进同一个基础镜像，而不是为每个 JDK 构建镜像，
因此所有 JDK 都运行在相同的用户空间中。

### cgroup-lab/docker/run-thread-matrix.sh

| 参数 | 说明 |
|---|---|
| `--jdk-root`、`--out`、`--host-label` | 同上（必填） |
| `--image`、`--probe-src`、`--jdks` | 同上 |
| `--thp-modes` | 测试的 THP 模式，默认 `never,madvise,always` |
| `--threads` | 线程数，默认 `0,200,1000` |
| `--xss` | `default` 或 `1m` 之类的大小，默认 `default,1m` |
| `--samples` | 所有线程启动后的采样时间点，默认 `5,30` 秒 |
| `--memory` | 容器内存限制，默认 `4g` |
| `--repeats` | 每个单元格的重复次数，默认 3 |
| `--oom-demo` | 在 1 GiB 限制、THP 为 `always` 的条件下启动 1000 个线程，运行 5 次 |
| `--timeout`、`--dry-run` | 同上 |

脚本在运行期间把 THP 模式写入 `/sys/kernel/mm/transparent_hugepage/enabled`，退出时恢复原值。NMT
（`-XX:NativeMemoryTracking=summary`）在 JVM 退出时与 RSS 一起输出。jdk8u 中没有
[JDK-8191369](https://bugs.openjdk.org/browse/JDK-8191369)（该修改使 NMT 只报告实际提交的线程栈页），因此在 JDK 8 上应把
NMT 与 RSS 结合起来解读，不要单看 NMT。

### cgroup-lab/eks/eks-up.sh

| 参数 | 说明 |
|---|---|
| `--region`、`--owner`、`--run-id`、`--k8s-version` | 必填 |
| `--cluster-name` | 默认 `jvm-cgroup-<run-id>` |
| `--api-allowed-cidr` | 将公有 API 端点限制为该 CIDR |
| `--kubeconfig`、`--profile` | 常规参数 |
| `--print-config` | 打印渲染后的 ClusterConfig，不调用 AWS |
| `--dry-run`、`--yes` | eksctl 试运行；跳过确认 |

集群使用公有子网、不创建 NAT 网关，包含四个各有一个节点的托管节点组：m8g.xlarge（AWS Graviton4）上的 `al2023-m8g` 和
`br-m8g`，m9g.xlarge（AWS Graviton5）上的 `al2023-m9g` 和 `br-m9g`。`al2023-*` 节点组运行 Amazon Linux 2023，标签为
`lab/os=al2023`；`br-*` 节点组运行 Bottlerocket，标签为 `lab/os=bottlerocket`。节点不开放 SSH，禁用 IMDSv1，卷均加密。
如需使用其他 arm64 实例类型，请修改 `cluster.yaml.tmpl` 中的 `instanceType`。

### cgroup-lab/eks/run-eks-matrix.sh

| 参数 | 说明 |
|---|---|
| `--instance-type` | 在该 arm64 实例类型的节点上运行，例如 `m8g.xlarge` 或 `m9g.xlarge`（必填） |
| `--jdks`、`--out` | JDK ID（使用清单中的 aarch64 构建）和结果目录（必填）；每种实例类型使用一个结果目录 |
| `--configs` | 只运行 `configs-eks.csv` 中的这些配置 |
| `--nodegroups` | `al2023`、`bottlerocket` 或两者（默认） |
| `--repeats-probe`、`--repeats-alloc` | 重复次数，默认 3 和 5 |
| `--image`、`--timeout` | 容器镜像；每个 Job 的等待时限，默认 900 秒 |
| `--skip-nodeinfo` | 不运行节点信息 Pod |
| `--print-job` | 打印 `OS,JDK_ID,CONFIG` 对应的 Job 清单后退出（不访问集群） |

配置（`cgroup-lab/configs-eks.csv`）：K1 的 requests 与 limits 均为 1 个 CPU 和 1 GiB；K2 为 2 个 CPU 和 1 GiB；K3 的 CPU
request 为 1、不设 CPU limit、内存 1 GiB；K4 和 K5 为 K2 分别加 `-Xmx512m` 和 `-XX:MaxRAMPercentage=75.0`；K6 至 K8 在 K2 下运行
`AllocPressure`，分别不加 JVM 标志、加 `-XX:MaxRAMPercentage=75.0`、加 `-Xmx768m`。每个 Job 的 init 容器通过 HTTPS 下载 JDK，
按清单校验 SHA-256，用 `extract_jdk.py` 解压（基础镜像中没有 tar），并编译探测程序。Pod 在 Pod 安全标准的"restricted"
级别下运行。Job 和节点信息 Pod 通过 `lab/os` 和 `node.kubernetes.io/instance-type` 选择节点，名称中带有实例系列
（`jvmlab-<os>-<family>-<n>`、`nodeinfo-<os>-<family>`），因此 m8g 和 m9g 上的运行可以共用同一个命名空间。节点信息 Pod
记录每个节点组的内核、cgroup 文件系统类型、THP 设置、页大小和 CPU 特性。`example-job.yaml` 是一个渲染后的 Job 示例。

### cgroup-lab/eks/eks-down.sh

`eks-down.sh --region REGION --run-id RUN_ID [--cluster-name NAME] [--execute [--yes]]` 会运行
`infra/cleanup.sh --eks-cluster NAME --verify`。

### infra/ec2-up.sh

| 参数 | 说明 |
|---|---|
| `--region`、`--owner`、`--run-id`、`--types` | 必填 |
| `--groups` | 主机分组；每个实例类型和分组各创建一个实例，默认 `g1` |
| `--volume-gib` | 根卷大小，gp3，加密，默认 50 |
| `--max-hours` | 用户数据中的关机定时器，默认 12 小时；实例关机即终止 |
| `--resources-log` | 每创建一个资源追加一行 JSON |
| `--profile`、`--dry-run`、`--yes` | 常规参数 |

脚本会创建 S3 存储桶 `legacy-java-graviton-<run-id>`（阻止公有访问、SSE-S3、只允许 TLS 的存储桶策略）、IAM 角色和实例配置文件
`legacy-java-graviton-<run-id>-ec2`、默认 VPC 中不含入站规则的安全组，并在第一个同时提供所有所需实例类型的可用区中创建实例。
如果该可用区没有某个实例类型的容量（`InsufficientInstanceCapacity`），该实例会创建在下一个同时提供所有所需实例类型的可用区中；
计划中会列出这些备用可用区。
实例使用公共 SSM 参数中最新的 Amazon Linux 2023 AMI，强制 IMDSv2，不使用密钥对，名称为
`legacy-java-graviton-<run-id>-<family>-<group>`，并带有标签 `lab-host=<family>-<group>`。

### infra/ec2-exec.sh

| 参数 | 说明 |
|---|---|
| `--region`、`--run-id`、`--instance-id` | 本次运行的实例（会检查其标签） |
| `--bundle`、`--script` | 要上传的目录，以及其中要运行的脚本 |
| `--profile` | 常规参数 |

### infra/collect.sh

`collect.sh --region REGION --run-id RUN_ID --dest DIR [--profile PROFILE]` 在检查存储桶标签后，从本次运行存储桶的
`results/` 执行 `aws s3 sync`。

### infra/cleanup.sh

| 参数 | 说明 |
|---|---|
| `--region`、`--run-id` | 必填 |
| `--eks-cluster` | 同时用 eksctl 删除该 EKS 集群（集群必须带有本次运行的标签） |
| `--execute`、`--yes` | 执行删除；不带 `--execute` 时只打印计划 |
| `--verify`、`--verify-out` | 列出仍然存在的资源，有残留时退出码为 1；以 JSON 格式写出结果 |
| `--profile` | 常规参数 |

## JDK 清单

`lib/jdks.csv` 列出 27 个压缩包（14 个 JDK ID，分 aarch64 和 x64；Corretto 8.292.10.2 只有 aarch64 构建），包括 URL、
`fetch-jdk.sh` 校验的 SHA-256、厂商发布的校验和及其来源：

| JDK ID | 选取原因 |
|---|---|
| `corretto-8.282.08.1` | 最后一个使用基于 IcedTea 的 AArch64 移植的 Corretto 8 |
| `corretto-8.292.10.1` | 第一个使用 OpenJDK 8u AArch64 移植的 Corretto 8 |
| `corretto-8.292.10.2` | 8.292 的仅 AArch64 更新版本，包含 JDK-8267689 的修复 |
| `corretto-8.362.08.1`、`temurin-8u362-b09` | 支持 cgroup v2 之前的最后一个 JDK 8 版本 |
| `corretto-8.372.07.1`、`temurin-8u372-b07` | 第一个支持 cgroup v2 的 JDK 8 版本 |
| `corretto-8.512.09.1`、`temurin-8u504-b01` | 撰写时最新的 JDK 8 构建 |
| `corretto-11.0.15.9.1`、`corretto-11.0.16.8.1` | 支持 cgroup v2 之前与开始支持时的 JDK 11 |
| `corretto-11.0.33.0.10`、`corretto-17.0.21.0.11`、`corretto-21.0.13.0.11` | 撰写时最新的 11、17 和 21 |

Corretto 8.282.08.1、8.292.10.1 和 8.292.10.2 的厂商只发布了 MD5 校验和。对于这几个构建，清单中的 SHA-256 是在校验厂商
MD5 和 GPG 签名（Corretto 发布密钥 `A122542AB04F24E3`）之后计算得到的（`checksum_source` 列注明了这一点）。其余取值均为
厂商发布的 SHA-256。

## self-check.sh 使用的版本阈值

以下阈值来自上游源码与记录。提交与标签信息读取自 [openjdk/jdk8u](https://github.com/openjdk/jdk8u) 仓库。最后一列是在[测试环境](#测试环境)
所列平台上测得的结果：除 `JavaCritical_` 崩溃（用一个不在本仓库中的 JNI 测试库测得）和标有 † 的结果（用不在本仓库中的一次性检查测得）外，
都来自本仓库中的实验。

| 检查项 | 阈值 | 来源 | 实验结果 |
|---|---|---|---|
| cgroup-v2 | JDK 8u372、11.0.16、15 | [JDK-8230305](https://bugs.openjdk.org/browse/JDK-8230305)"Cgroups v2: Container awareness"；在 jdk8u 中首次出现于标签 `jdk8u372-b01`，不在 `jdk8u362-b09` 中 | 已证实（cgroup v2：c8g、c9g、c8i、c8a 上的 EC2 docker；m8g、m9g 上的 EKS Amazon Linux 2023 与 Bottlerocket）：8u362 按宿主机内存确定堆大小，8u372 按 1 GiB 限制确定；c9g 上 11.0.15（宿主机内存）和 11.0.16（限制）也是如此。在切换到 cgroup v1 的 c9g 主机上，8u362 能读到限制 |
| container | JDK 8u191、10 | [JDK-8146115](https://bugs.openjdk.org/browse/JDK-8146115)"Improve docker container detection and resource configuration usage"（引入 `UseContainerSupport`），首次出现于 `jdk8u191-b02` | 未测量：所有被测构建都晚于 8u191 |
| aarch64-port | JDK 8u292 | [JDK-8257192](https://bugs.openjdk.org/browse/JDK-8257192)"Integrate AArch64 JIT port into 8u"，首次出现于 `jdk8u292-b01`；[Corretto 8 变更日志](https://github.com/corretto/corretto-8/blob/develop/CHANGELOG.md)在 8.292.10.1 中说明替换了基于 IcedTea 的移植 | 未观察到由移植切换本身导致的故障：在 c8g 和 c9g 上，Corretto 8.282.08.1 与 8.292.10.1 在复现程序和 30 分钟稳定性测试中表现相同 |
| jdk-8267689 | JDK 8u302、Corretto 8.292.10.2 | [JDK-8267689](https://bugs.openjdk.org/browse/JDK-8267689)，首次出现于 `jdk8u302-b05`；Corretto [拉取请求 303](https://github.com/corretto/corretto-8/pull/303) 是标签 8.292.10.1 与 8.292.10.2 之间唯一的 HotSpot 改动 | 已证实：在 c8g 和 c9g 上，复现程序在 Corretto 8.282.08.1 和 8.292.10.1 的每次 JIT 运行中都读到错误值；Corretto 8.292.10.2 及以后、Temurin 8u362 和 8u504、`-Xint` 以及 c8i、c8a 上均未出现 |
| stack-thp | AArch64 上 `ThreadStackSize` 为 2048 且 THP 为 `always` | [JDK-8303215](https://bugs.openjdk.org/browse/JDK-8303215)"Make thread stacks not use huge pages"，首次出现于 `jdk8u512-b01` | 取决于内核，因此只输出 INFO。在运行 Amazon Linux 2（内核 5.10）、THP 为 `always` 的 c8g 上，Corretto 8.372（2048 KB 栈）每线程 2038.7 至 2058.9 KiB，8.512（2040 KB）187.6 至 200.5 KiB；THP 为 `never` 时 149.7 至 152.1 KiB †。在 Amazon Linux 2023（内核 6.18，所有线程栈都不使用大页 †）上，THP `always` 使每线程多 12.9 至 18.3 KiB |
| javacritical | AArch64 上 `CriticalJNINatives` 为 true 的 JDK 8：Corretto 8（实测 8.282、8.362、8.372、8.512）；Temurin 8 和 Corretto 8.292.x 为 false | Corretto 8 源码：上游 jdk8u 和 Corretto 8.322.06.1 及以前在 aarch64 上关闭该标志（`vm_version_aarch64.cpp`）；从 Corretto 8.332.08.1 起这段代码不再存在，而 `sharedRuntime_aarch64.cpp` 中 critical native 所需的 aarch64 辅助函数在 8.512.09.1 中仍是 `Unimplemented()` | 在 c8g、c9g 上，以及运行 Amazon Linux 2 RPM 的 c8g 上已证实：编译带 `JavaCritical_` 入口的方法时以退出码 134 结束，报"Internal Error (sharedRuntime_aarch64.cpp:1045) Unimplemented()"（8.282 为第 1035 行）；加 `-XX:-CriticalJNINatives` 后无故障；c8i 上所有 JDK 运行无故障。`nm` 在每个被测 JDK 8 自带的 38 至 48 个库中找到 0 个 `JavaCritical_` 函数 |

PASS 表示该 JDK 已越过这些阈值，并不表示它没有其他缺陷。

## 费用

实验会创建计费资源。请在 [Amazon EC2](https://aws.amazon.com/ec2/pricing/on-demand/)、
[Amazon EKS](https://aws.amazon.com/eks/pricing/)、[Amazon EBS](https://aws.amazon.com/ebs/pricing/)、
[Amazon VPC](https://aws.amazon.com/vpc/pricing/)（公有 IPv4 地址）和 [Amazon S3](https://aws.amazon.com/s3/pricing/)
定价页面查看当前价格。可按以下方式估算一次运行的费用：

- EC2：各实例类型的实例小时数乘以按需价格，加上根卷的 EBS gp3 GiB-月（默认每个 50 GiB），以及每个实例每小时一个公有 IPv4 地址。
- EKS：控制平面小时数乘以集群小时价格，加上四个节点（m8g.xlarge 和 m9g.xlarge 的实例小时、EBS 和公有 IPv4）。测试集群不含 NAT 网关。
- S3：费用很小（bundle 与结果），下载结果时另有数据传出费用。

实例设有关机定时器（`--max-hours`），关机即终止，因此遗忘的主机最多运行到定时器结束。EKS 集群的实验完成后请立即删除。

## 清理

1. `infra/cleanup.sh --region R --run-id ID` 打印计划：每个资源标记为 `delete`、`skip (not tagged for run ID)` 或
   `absent`。
2. `--execute` 按以下顺序删除：EKS 集群（使用 `--eks-cluster` 时）、实例（并等待其终止）、残留的可用状态卷、安全组、
   密钥对、实例配置文件与角色、存储桶（先删除对象）。
3. `--verify` 列出本次运行仍然存在的所有资源（未终止的实例、卷、快照、AMI、安全组、密钥对、NAT 网关、弹性 IP、EKS 集群、
   CloudFormation 堆栈 `eksctl-<cluster>-*`、IAM 角色和存储桶，以及 Resource Groups Tagging API 报告的其他带本次运行
   标签的资源），有残留时退出码为 1。Tagging API 可能在一小时或更长时间内仍列出已删除的资源。对于它列出的 EC2 实例、卷和网络接口，
   `--verify` 会用 `describe-*` 再次检查，把已不存在的资源（以及已终止的实例）打印为“listed by the tagging API but
   already deleted”，且不计入残留；对于其他资源类型，请稍后再次运行 `--verify`。

只有带有标签 `project=sample-legacy-java-graviton-readiness` 和 `run-id=<run-id>` 的资源才会被删除。名称相同但不带这些标签的
资源只会被报告并保留。EKS 集群的节点、节点卷和安全组同样带有本次运行的标签；它们会作为集群的一部分被报告并保留，由 eksctl 随集群一起删除。

## 安全注意事项

- EC2 主机的安全组没有入站规则，也不使用密钥对；通过 Session Manager 访问。强制 IMDSv2，根卷加密。
- S3 存储桶阻止公有访问，使用 SSE-S3，并拒绝非 TLS 请求。实例角色只能读写该存储桶中的对象，另有
  `AmazonSSMManagedInstanceCore` 提供的 Session Manager 权限。
- JDK 只通过 HTTPS 下载，每个压缩包在解压前都会与固定的 SHA-256 比对。容器镜像按摘要固定。
- 容器以非 root 用户运行，不授予 capability，禁止权限提升，根文件系统只读，docker 实验中不提供网络。EKS Pod 在"restricted"
  Pod 安全标准下运行，不挂载服务账号令牌。
- `run-thread-matrix.sh` 在运行期间修改主机的 THP 模式（退出时恢复）。请只在专用测试主机上运行。
- 未指定 `--api-allowed-cidr` 时，EKS 公有 API 端点接受来自所有地址的请求（请求仍需有效凭证）。
- eksctl 按其默认设置创建 EKS 集群和节点组的 IAM 角色及安全组，参见 [eksctl 文档](https://eksctl.io/usage/minimum-iam-policies/)。
- 请使用沙箱账号和最小权限角色（参见 [IAM 权限](#iam-权限)）。

## 限制

- 仅支持 AWS 商业分区；脚本拒绝中国区域、AWS GovCloud (US) 和 AWS European Sovereign Cloud 的区域。
- docker 实验需要安装了 docker 的 Linux 主机；EKS 实验只使用 arm64 节点，x86 对照数据来自 EC2 实验。
- 测量范围为 AWS Graviton4 和 Graviton5。脚本可以在任何一代 arm64 上运行，但更早几代的结果不在本仓库的范围内。
- EKS 用户指南没有说明 Bottlerocket 对 Graviton5 的支持。m9g.xlarge 上的 Bottlerocket 节点进入 Ready 状态并运行了实验的全部
  Pod；这只是观察结果，不是支持声明。
- `self-check.sh --native-libs` 只读取您指定的文件，找不到应用在运行时从 JAR 文件中解压出来的库。
- 实验记录 JVM 默认值和容器中的行为，不测量性能。
- JDK 清单是固定列表，不覆盖其他厂商和构建；如需测试，可添加带厂商 SHA-256 的行。
- `self-check.sh` 只检查上表中的阈值。

## 测试环境

这些脚本在 us-east-1 运行，版本如下：

| 组件 | 版本 |
|---|---|
| EC2 实例类型 | c8g.2xlarge（AWS Graviton4）、c9g.2xlarge（AWS Graviton5），以及作为 x86 对照的 c8i.2xlarge（Intel Xeon 6975P-C）和 c8a.2xlarge（AMD EPYC 9R45）；均为 8 个 vCPU、16 GiB |
| EC2 AMI | 通过 SSM 参数 `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64` 和 `-x86_64` 获取的 Amazon Linux 2023 AMI（Amazon Linux 2023.12.20261102，内核 6.18.56-125.164.amzn2023）；THP 与 RPM 检查另用一台运行 Amazon Linux 2（2.0.20261102.0，内核 5.10.271-272.1121.amzn2）的 c8g.2xlarge |
| 主机设置 | cgroup v2（`cgroup2fs`），THP 默认 `madvise`，4 KiB 页；在 c9g 上以 `systemd.unified_cgroup_hierarchy=0` 做 cgroup v1 对照 |
| EC2 上的容器运行时 | Docker 25.0.18、containerd 2.3.7、runc 1.4.3 |
| 容器镜像 | `public.ecr.aws/amazonlinux/amazonlinux:2023`，摘要固定在 `lib/common.sh` 中 |
| Amazon EKS | Kubernetes 1.37、eksctl 0.231.0-dev、kubectl 1.35.0；节点组 `al2023-m8g`、`br-m8g`（m8g.xlarge）和 `al2023-m9g`、`br-m9g`（m9g.xlarge）采用 `cluster.yaml.tmpl` 中的设置，用 `eksctl create nodegroup` 加入由 `eks-up.sh` 创建的集群 |
| EKS 节点组 | Amazon Linux 2023 节点组版本 1.37.1-20261107（containerd 2.3.7）；Bottlerocket 1.68.1 `aws-k8s-1.37`（containerd 2.3.6）；内核均为 6.18.56，cgroup v2，THP `madvise`，4 个 vCPU |
| JDK | `lib/jdks.csv` 中全部 14 个 ID（c8g、c9g 上用 aarch64 构建，c8i、c8a 上用 x64 构建；`corretto-8.292.10.2` 没有 x64 构建），以及 Amazon Linux 2 RPM `java-1.8.0-amazon-corretto-devel-1.8.0_512.b09-1.amzn2` |

## 测试

测试离线运行。`tests/run-tests.sh` 用 `tests/stubs` 中的桩程序替换 `aws`、`eksctl`、`kubectl`、`docker`、`journalctl`、
`objdump`、`nm`、`timeout` 和 `uname`，在临时目录中创建模拟的 JDK 启动器，并在其中运行每个脚本。测试不使用 AWS 凭证，
也不访问网络。

```bash
bash tests/run-tests.sh
# also compile the Java programs with -Xlint:all -Werror and run their self-tests:
JAVA8_HOME=/path/to/jdk8 JAVA21_HOME=/path/to/jdk21 bash tests/run-tests.sh
```

测试覆盖参数校验、试运行输出、确认处理、校验和验证、针对 JDK 8、11 和 21 输出格式的标志解析、自检阈值及其
`JavaCritical_` 检查（使用模拟的库文件和 `nm` 桩程序）、docker 和
Kubernetes 命令行、标签检查以及清理顺序。运行测试需要 bash 3.2 或更高版本、jq 和 python3。

## 第三方工具与许可证

本仓库只包含其中的脚本、程序和文档，不包含也不再分发任何 JDK 或工具；JDK 由脚本在运行时下载，工具由您自行安装。

| 软件 | 许可证 | 使用方式 |
|---|---|---|
| Amazon Corretto、Eclipse Temurin（JDK 构建） | GPL-2.0 with Classpath Exception | 由 `fetch-jdk.sh` 和 EKS init 容器在运行时下载 |
| Amazon Linux 2023 容器镜像 | 见镜像 | 运行时作为基础镜像拉取 |
| AWS CLI v2、kubectl、eksctl | Apache-2.0 | 由您安装 |
| jq | MIT | 由您安装 |
| docker | Apache-2.0 | 由您安装，或由 `ec2-up.sh` 安装在主机上 |
| bash、curl、tar、coreutils、binutils、Python 3 | GPL-3.0（bash、coreutils、binutils、tar）、curl 许可证、PSF-2.0 | 由您安装或随操作系统提供 |

博客文章的内存模型和微基准测量还用到了 jcstress 和 JMH（GPL-2.0 with Classpath Exception）。它们以及用它们编写的测试和基准都不在
本仓库中。

## 计划中的模块

Java 内存模型实验（对比 Arm 与 x86 内存模型下的数据竞争）可能在许可证评审之后加入。

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.（安全问题的报告方式参见 CONTRIBUTING。）

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.（本库采用 MIT-0 许可证，详见 LICENSE 文件。）

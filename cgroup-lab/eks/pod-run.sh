#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Main container of the cgroup lab Job (mounted from the ConfigMap at /src). Prints three
# sections, each starting with a "=== name" line: the JVM's container detection log, the
# output of -XshowSettings:system, and the probe (ContainerProbe) or allocation
# (AllocPressure) output. The last program replaces this shell, so an OOM kill is reported
# for the container. Environment: PROGRAM (probe or alloc), JDK_MAJOR, JVM_FLAGS.
set -uo pipefail
: "${PROGRAM:?}" "${JDK_MAJOR:?}"
JAVA=/work/jdk/bin/java
read -r -a FLAGS <<<"${JVM_FLAGS:-}"
echo "=== container-log"
if [ "$JDK_MAJOR" = 8 ]; then
  "$JAVA" ${FLAGS[@]+"${FLAGS[@]}"} -XX:+UnlockDiagnosticVMOptions -XX:+PrintContainerInfo -version 2>&1
else
  "$JAVA" ${FLAGS[@]+"${FLAGS[@]}"} -Xlog:os+container=trace -version 2>&1
fi
echo "=== showsettings-system"
"$JAVA" ${FLAGS[@]+"${FLAGS[@]}"} -XshowSettings:system -version 2>&1
echo "=== $PROGRAM"
case "$PROGRAM" in
  probe) exec "$JAVA" ${FLAGS[@]+"${FLAGS[@]}"} -cp /work/classes ContainerProbe ;;
  alloc) exec "$JAVA" ${FLAGS[@]+"${FLAGS[@]}"} -cp /work/classes AllocPressure ;;
  *) echo "unknown PROGRAM $PROGRAM" >&2; exit 2 ;;
esac

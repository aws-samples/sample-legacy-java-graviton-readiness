/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

import java.io.File;
import java.io.IOException;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.OperatingSystemMXBean;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ForkJoinPool;

/**
 * Prints one JSON object that shows what the JVM detected about its container: memory and CPU
 * limits, the heap size and thread counts it derived from them, and the cgroup files the
 * kernel exposes. Java 8 source level, JDK APIs only.
 *
 * <p>Usage: {@code java ContainerProbe [--self-test]}. With {@code --self-test} the probe also
 * checks its JSON writer and exits with 1 if that check fails.
 */
public final class ContainerProbe {

    private static final String[] VM_OPTIONS = {
        "MaxHeapSize", "InitialHeapSize", "MaxRAM", "MaxRAMPercentage", "ParallelGCThreads",
        "ConcGCThreads", "CICompilerCount", "UseContainerSupport", "ActiveProcessorCount",
        "UseG1GC", "UseParallelGC", "UseSerialGC", "ThreadStackSize", "UseContainerCpuShares",
        "PreferContainerQuotaForCPUCount", "UseTransparentHugePages",
    };

    private static final String[] CGROUP_V2_FILES = {
        "memory.max", "memory.current", "memory.swap.max", "memory.high", "cpu.max",
        "cpu.weight", "cpuset.cpus.effective",
    };

    private static final String[] CGROUP_V1_FILES = {
        "memory/memory.limit_in_bytes", "memory/memory.usage_in_bytes",
        "cpu/cpu.cfs_quota_us", "cpu/cpu.cfs_period_us", "cpu/cpu.shares",
        "cpuset/cpuset.effective_cpus",
    };

    private ContainerProbe() {
    }

    public static void main(String[] args) {
        boolean selfTest = false;
        for (String a : args) {
            if ("--self-test".equals(a)) {
                selfTest = true;
            } else {
                System.err.println("usage: java ContainerProbe [--self-test]");
                System.exit(2);
            }
        }
        if (selfTest && !Json.selfTest()) {
            System.err.println("ContainerProbe: JSON writer self-test failed");
            System.exit(1);
        }
        Json j = new Json();
        j.begin();
        j.field("probe", "ContainerProbe");
        j.field("self_test", selfTest);
        String[] props = {"java.version", "java.vendor", "java.vm.name", "java.vm.version",
            "java.runtime.version", "os.name", "os.arch", "os.version"};
        for (String p : props) {
            j.field(p.replace('.', '_'), System.getProperty(p));
        }
        Runtime rt = Runtime.getRuntime();
        j.field("available_processors", rt.availableProcessors());
        j.field("runtime_max_memory", rt.maxMemory());
        j.field("runtime_total_memory", rt.totalMemory());
        j.field("fork_join_common_parallelism", ForkJoinPool.commonPool().getParallelism());
        j.field("os_total_physical_memory", totalPhysicalMemory());

        j.key("vm_options");
        j.begin();
        for (String name : VM_OPTIONS) {
            j.field(name, vmOption(name));
        }
        j.end();

        List<String> gcs = new ArrayList<String>();
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            gcs.add(gc.getName());
        }
        j.field("gc_names", gcs);

        j.field("proc_threads", Linux.statusField("Threads"));
        j.field("proc_vmrss_kb", Linux.statusKb("VmRSS"));
        j.field("cgroup_fs_type", Linux.mountFsType("/sys/fs/cgroup"));
        j.field("proc_self_cgroup", Linux.read("/proc/self/cgroup"));
        j.key("cgroup_files");
        j.begin();
        for (String f : CGROUP_V2_FILES) {
            j.field(f, Linux.read("/sys/fs/cgroup/" + f));
        }
        for (String f : CGROUP_V1_FILES) {
            j.field("v1:" + f, Linux.read("/sys/fs/cgroup/" + f));
        }
        j.end();
        j.field("thp_enabled", Linux.read("/sys/kernel/mm/transparent_hugepage/enabled"));
        j.field("thp_defrag", Linux.read("/sys/kernel/mm/transparent_hugepage/defrag"));
        j.end();
        System.out.println(j);
    }

    /** Value of a VM option as a string, or null when this JVM does not have the option. */
    static String vmOption(String name) {
        try {
            com.sun.management.HotSpotDiagnosticMXBean bean =
                ManagementFactory.getPlatformMXBean(com.sun.management.HotSpotDiagnosticMXBean.class);
            return bean.getVMOption(name).getValue();
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /**
     * Total physical memory as reported by the OS MXBean. Called through the public
     * com.sun.management interface by reflection, because the method was renamed in JDK 14.
     */
    static Long totalPhysicalMemory() {
        OperatingSystemMXBean os = ManagementFactory.getOperatingSystemMXBean();
        try {
            Class<?> iface = Class.forName("com.sun.management.OperatingSystemMXBean");
            if (!iface.isInstance(os)) {
                return null;
            }
            Method m = iface.getMethod("getTotalPhysicalMemorySize");
            return (Long) m.invoke(os);
        } catch (ReflectiveOperationException e) {
            return null;
        }
    }

    /** Linux /proc and /sys readers. Each returns null when the file does not exist. */
    static final class Linux {
        private Linux() {
        }

        static String read(String path) {
            File f = new File(path);
            if (!f.isFile()) {
                return null;
            }
            try {
                return new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8).trim();
            } catch (IOException e) {
                return "unreadable: " + e.getClass().getSimpleName();
            }
        }

        /** Content of the first of the given files that exists, or null. */
        static String firstOf(String... paths) {
            for (String p : paths) {
                String v = read(p);
                if (v != null) {
                    return v;
                }
            }
            return null;
        }

        /** Memory use of this cgroup: memory.current (v2) or memory.usage_in_bytes (v1). */
        static String cgroupMemoryCurrent() {
            return firstOf("/sys/fs/cgroup/memory.current",
                "/sys/fs/cgroup/memory/memory.usage_in_bytes");
        }

        /** Memory limit of this cgroup: memory.max (v2) or memory.limit_in_bytes (v1). */
        static String cgroupMemoryMax() {
            return firstOf("/sys/fs/cgroup/memory.max",
                "/sys/fs/cgroup/memory/memory.limit_in_bytes");
        }

        /**
         * Value of one "key value" line (memory.stat) or "key value kB" line (smaps_rollup),
         * or null.
         */
        static Long statValue(String path, String key) {
            String text = read(path);
            if (text == null) {
                return null;
            }
            for (String line : text.split("\n")) {
                String[] f = line.trim().split("\\s+");
                if ((f.length == 2 || f.length == 3) && f[0].equals(key)) {
                    try {
                        return Long.valueOf(f[1]);
                    } catch (NumberFormatException e) {
                        return null;
                    }
                }
            }
            return null;
        }

        static String statusField(String key) {
            String status = read("/proc/self/status");
            if (status == null) {
                return null;
            }
            for (String line : status.split("\n")) {
                if (line.startsWith(key + ":")) {
                    return line.substring(key.length() + 1).trim();
                }
            }
            return null;
        }

        static Long statusKb(String key) {
            String v = statusField(key);
            if (v == null) {
                return null;
            }
            String digits = v.replace("kB", "").trim();
            try {
                return Long.valueOf(digits);
            } catch (NumberFormatException e) {
                return null;
            }
        }

        /** File system type of the mount at mountPoint, from /proc/self/mountinfo. */
        static String mountFsType(String mountPoint) {
            String info = read("/proc/self/mountinfo");
            if (info == null) {
                return null;
            }
            String found = null;
            for (String line : info.split("\n")) {
                String[] f = line.split(" ");
                if (f.length < 5 || !mountPoint.equals(f[4])) {
                    continue;
                }
                int sep = line.indexOf(" - ");
                if (sep >= 0) {
                    String[] tail = line.substring(sep + 3).split(" ");
                    found = tail[0]; // the last matching line is the visible mount
                }
            }
            return found;
        }
    }

    /** Minimal JSON writer: objects, strings, numbers, booleans, string lists, null. */
    static final class Json {
        private final StringBuilder sb = new StringBuilder();
        private boolean first = true;

        void begin() {
            sb.append('{');
            first = true;
        }

        void end() {
            sb.append('}');
            first = false;
        }

        void key(String k) {
            if (!first) {
                sb.append(',');
            }
            first = false;
            quote(k);
            sb.append(':');
        }

        void field(String k, Object v) {
            key(k);
            value(v);
        }

        private void value(Object v) {
            if (v == null) {
                sb.append("null");
            } else if (v instanceof Number || v instanceof Boolean) {
                sb.append(v);
            } else if (v instanceof List) {
                sb.append('[');
                boolean f = true;
                for (Object o : (List<?>) v) {
                    if (!f) {
                        sb.append(',');
                    }
                    f = false;
                    value(o);
                }
                sb.append(']');
            } else {
                quote(v.toString());
            }
        }

        private void quote(String s) {
            sb.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (c < 0x20) {
                            sb.append(String.format("\\u%04x", (int) c));
                        } else {
                            sb.append(c);
                        }
                }
            }
            sb.append('"');
        }

        @Override
        public String toString() {
            return sb.toString();
        }

        static boolean selfTest() {
            Json j = new Json();
            j.begin();
            j.field("a", "q\"b\\s\n\t\u0001");
            j.field("n", 42L);
            j.field("z", null);
            j.end();
            return "{\"a\":\"q\\\"b\\\\s\\n\\t\\u0001\",\"n\":42,\"z\":null}".equals(j.toString());
        }
    }
}

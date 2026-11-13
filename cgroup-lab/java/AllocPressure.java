/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import java.util.ArrayList;
import java.util.List;

/**
 * Retains 1 MiB byte arrays, writes to every 4 KiB of each array so that the memory is
 * resident, and prints a JSON line every 32 MiB with the elapsed time, heap use, the
 * process RSS and the cgroup memory use. It ends in one of three ways: the JVM throws
 * OutOfMemoryError (prints an "oome" line and exits with 3), the kernel kills the process
 * (no final line; the caller reads the container exit code), or --max-mib is reached
 * (prints a "done" line and exits with 0).
 *
 * <p>Usage: {@code java AllocPressure [--chunk-kib N] [--pause-ms N] [--report-mib N]
 * [--max-mib N] [--self-test]}. Compiled together with ContainerProbe, whose JSON writer and
 * Linux readers it uses.
 */
public final class AllocPressure {

    private static final int PAGE = 4096;

    private AllocPressure() {
    }

    public static void main(String[] args) throws InterruptedException {
        int chunkKib = 1024;
        int pauseMs = 10;
        int reportMib = 32;
        long maxMib = 0; // 0 = until the JVM or the kernel stops the process
        boolean selfTest = false;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--self-test".equals(a)) {
                selfTest = true;
            } else if (i + 1 < args.length && "--chunk-kib".equals(a)) {
                chunkKib = Integer.parseInt(args[++i]);
            } else if (i + 1 < args.length && "--pause-ms".equals(a)) {
                pauseMs = Integer.parseInt(args[++i]);
            } else if (i + 1 < args.length && "--report-mib".equals(a)) {
                reportMib = Integer.parseInt(args[++i]);
            } else if (i + 1 < args.length && "--max-mib".equals(a)) {
                maxMib = Long.parseLong(args[++i]);
            } else {
                System.err.println("usage: java AllocPressure [--chunk-kib N] [--pause-ms N]"
                    + " [--report-mib N] [--max-mib N] [--self-test]");
                System.exit(2);
            }
        }
        if (selfTest) {
            maxMib = 8;
            pauseMs = 0;
            reportMib = 4;
            if (!ContainerProbe.Json.selfTest()) {
                System.err.println("AllocPressure: JSON writer self-test failed");
                System.exit(1);
            }
        }
        final long start = System.nanoTime();
        Runtime rt = Runtime.getRuntime();
        ContainerProbe.Json s = new ContainerProbe.Json();
        s.begin();
        s.field("event", "start");
        s.field("self_test", selfTest);
        s.field("java_version", System.getProperty("java.version"));
        s.field("runtime_max_memory", rt.maxMemory());
        s.field("available_processors", rt.availableProcessors());
        s.field("memory_max", ContainerProbe.Linux.cgroupMemoryMax());
        s.field("chunk_kib", chunkKib);
        s.field("pause_ms", pauseMs);
        s.end();
        System.out.println(s);

        List<byte[]> retained = new ArrayList<byte[]>();
        long allocatedKib = 0;
        long nextReportKib = (long) reportMib * 1024;
        try {
            while (maxMib == 0 || allocatedKib < maxMib * 1024) {
                byte[] chunk = new byte[chunkKib * 1024];
                for (int off = 0; off < chunk.length; off += PAGE) {
                    chunk[off] = 1;
                }
                retained.add(chunk);
                allocatedKib += chunkKib;
                if (allocatedKib >= nextReportKib) {
                    System.out.println(progress("progress", start, allocatedKib));
                    nextReportKib += (long) reportMib * 1024;
                }
                if (pauseMs > 0) {
                    Thread.sleep(pauseMs);
                }
            }
        } catch (OutOfMemoryError e) {
            int chunks = retained.size();
            retained = null; // release the heap so that the report can be written
            ContainerProbe.Json o = new ContainerProbe.Json();
            o.begin();
            o.field("event", "oome");
            o.field("ms", (System.nanoTime() - start) / 1000000L);
            o.field("allocated_mib", allocatedKib / 1024);
            o.field("chunks", chunks);
            o.field("message", String.valueOf(e.getMessage()));
            o.end();
            System.out.println(o);
            System.out.flush();
            System.exit(3);
        }
        System.out.println(progress("done", start, allocatedKib));
    }

    private static String progress(String event, long start, long allocatedKib) {
        MemoryUsage heap = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        ContainerProbe.Json p = new ContainerProbe.Json();
        p.begin();
        p.field("event", event);
        p.field("ms", (System.nanoTime() - start) / 1000000L);
        p.field("allocated_mib", allocatedKib / 1024);
        p.field("heap_used", heap.getUsed());
        p.field("heap_committed", heap.getCommitted());
        p.field("vmrss_kb", ContainerProbe.Linux.statusKb("VmRSS"));
        p.field("memory_current", ContainerProbe.Linux.cgroupMemoryCurrent());
        p.end();
        return p.toString();
    }
}

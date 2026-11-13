/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;

/**
 * Starts N platform threads. Each thread recurses a fixed number of frames (a method with
 * sixteen long locals) and then blocks in the deepest frame, so every thread has touched a
 * similar amount of its stack. After all threads are blocked, the program prints one JSON
 * line per sample time with the process RSS, the anonymous huge page share from
 * /proc/self/smaps_rollup and the cgroup memory figures. Then it releases the threads and
 * exits normally, so that -XX:+PrintNMTStatistics can print the NMT summary at exit.
 *
 * <p>Usage: {@code java ThreadFootprint [--threads N] [--stack-depth N] [--samples S1,S2]
 * [--self-test]}. Sample times are seconds after the last thread blocked. Compiled together
 * with ContainerProbe, whose JSON writer and Linux readers it uses.
 */
public final class ThreadFootprint {

    private ThreadFootprint() {
    }

    public static void main(String[] args) throws InterruptedException {
        int threads = 200;
        int depth = 256;
        String samples = "5,30";
        boolean selfTest = false;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--self-test".equals(a)) {
                selfTest = true;
            } else if (i + 1 < args.length && "--threads".equals(a)) {
                threads = Integer.parseInt(args[++i]);
            } else if (i + 1 < args.length && "--stack-depth".equals(a)) {
                depth = Integer.parseInt(args[++i]);
            } else if (i + 1 < args.length && "--samples".equals(a)) {
                samples = args[++i];
            } else {
                System.err.println("usage: java ThreadFootprint [--threads N] [--stack-depth N]"
                    + " [--samples S1,S2] [--self-test]");
                System.exit(2);
            }
        }
        if (selfTest) {
            threads = 4;
            samples = "0";
            if (!ContainerProbe.Json.selfTest()) {
                System.err.println("ThreadFootprint: JSON writer self-test failed");
                System.exit(1);
            }
        }
        final int frames = depth;
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch ready = new CountDownLatch(threads);
        List<Thread> started = new ArrayList<Thread>();
        String createError = null;
        long t0 = System.nanoTime();
        for (int i = 0; i < threads; i++) {
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    sink += recurse(frames, ready, release);
                }
            }, "footprint-" + i);
            t.setDaemon(true);
            try {
                t.start();
            } catch (OutOfMemoryError e) {
                createError = String.valueOf(e.getMessage());
                break;
            }
            started.add(t);
        }
        // Threads that could not be created will never count down.
        for (int i = started.size(); i < threads; i++) {
            ready.countDown();
        }
        ready.await();
        long readyMs = (System.nanoTime() - t0) / 1000000L;
        long readyAt = System.nanoTime();
        for (String sec : samples.split(",")) {
            long target = readyAt + Long.parseLong(sec.trim()) * 1000000000L;
            long wait = (target - System.nanoTime()) / 1000000L;
            if (wait > 0) {
                Thread.sleep(wait);
            }
            System.out.println(sample(sec.trim(), threads, started.size(), frames, readyMs,
                createError, selfTest));
        }
        release.countDown();
        for (Thread t : started) {
            t.join();
        }
    }

    static volatile long sink;

    /** Recurses depth frames, then blocks until release opens. Returns a value so the JIT keeps the locals. */
    static long recurse(int depth, CountDownLatch ready, CountDownLatch release) {
        long a0 = depth, a1 = a0 + 1, a2 = a1 + 2, a3 = a2 + 3, a4 = a3 + 4, a5 = a4 + 5;
        long a6 = a5 + 6, a7 = a6 + 7, a8 = a7 + 8, a9 = a8 + 9, a10 = a9 + 10, a11 = a10 + 11;
        long a12 = a11 + 12, a13 = a12 + 13, a14 = a13 + 14, a15 = a14 + 15;
        long r;
        if (depth > 0) {
            r = recurse(depth - 1, ready, release);
        } else {
            ready.countDown();
            boolean done = false;
            while (!done) {
                try {
                    release.await();
                    done = true;
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    done = true;
                }
            }
            r = 0;
        }
        return r + a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15;
    }

    private static String sample(String sec, int requested, int created, int depth, long readyMs,
                                 String createError, boolean selfTest) {
        String rollup = "/proc/self/smaps_rollup";
        ContainerProbe.Json j = new ContainerProbe.Json();
        j.begin();
        j.field("event", "sample");
        j.field("self_test", selfTest);
        j.field("sample_s", Long.valueOf(sec));
        j.field("java_version", System.getProperty("java.version"));
        j.field("os_arch", System.getProperty("os.arch"));
        j.field("threads_requested", requested);
        j.field("threads_created", created);
        j.field("create_error", createError);
        j.field("stack_depth", depth);
        j.field("ready_ms", readyMs);
        j.field("proc_threads", ContainerProbe.Linux.statusField("Threads"));
        j.field("vmrss_kb", ContainerProbe.Linux.statusKb("VmRSS"));
        j.field("rollup_rss_kb", ContainerProbe.Linux.statValue(rollup, "Rss:"));
        j.field("rollup_anon_kb", ContainerProbe.Linux.statValue(rollup, "Anonymous:"));
        j.field("rollup_anon_huge_kb", ContainerProbe.Linux.statValue(rollup, "AnonHugePages:"));
        j.field("memory_current", ContainerProbe.Linux.cgroupMemoryCurrent());
        j.field("memory_stat_anon", ContainerProbe.Linux.statValue("/sys/fs/cgroup/memory.stat", "anon"));
        j.field("memory_stat_anon_thp", ContainerProbe.Linux.statValue("/sys/fs/cgroup/memory.stat", "anon_thp"));
        j.field("thp_enabled", ContainerProbe.Linux.read("/sys/kernel/mm/transparent_hugepage/enabled"));
        j.end();
        return j.toString();
    }
}

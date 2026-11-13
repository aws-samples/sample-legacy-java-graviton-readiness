/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Random;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.CRC32;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Soak workload that exercises JIT intrinsics and runtime stubs which differ between CPU
 * architectures: AES/GCM, SHA-256, CRC32, BigInteger.modPow, regular expressions,
 * ConcurrentHashMap and AtomicLong under contention, and System.arraycopy between arrays of
 * different component types (the checked arraycopy stub). Every phase checks its result
 * against a known answer or an independent computation. The program prints one JSON line per
 * report interval and a final summary, and exits with 1 if any check failed.
 *
 * <p>Usage: {@code java SanityWorkload [--seconds N] [--report-seconds N] [--self-test]}.
 */
public final class SanityWorkload {

    private static final String[] PHASES = {
        "aes_gcm", "sha256", "crc32", "modpow", "regex", "concurrent", "arraycopy",
    };
    private static final long[] ROUNDS = new long[PHASES.length];
    private static final long[] FAILURES = new long[PHASES.length];

    private SanityWorkload() {
    }

    public static void main(String[] args) throws Exception {
        long seconds = 60;
        long reportSeconds = 60;
        boolean selfTest = false;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--self-test".equals(a)) {
                selfTest = true;
            } else if (i + 1 < args.length && "--seconds".equals(a)) {
                seconds = Long.parseLong(args[++i]);
            } else if (i + 1 < args.length && "--report-seconds".equals(a)) {
                reportSeconds = Long.parseLong(args[++i]);
            } else {
                System.err.println("usage: java SanityWorkload [--seconds N] [--report-seconds N] [--self-test]");
                System.exit(2);
            }
        }
        long start = System.nanoTime();
        long end = start + seconds * 1000000000L;
        long nextReport = start + reportSeconds * 1000000000L;
        int threads = 2 * Runtime.getRuntime().availableProcessors();
        do {
            runPhase(0, aesGcm());
            runPhase(1, sha256());
            runPhase(2, crc32());
            runPhase(3, modPow());
            runPhase(4, regex());
            runPhase(5, concurrent(threads, selfTest ? 1000 : 200000));
            runPhase(6, arraycopy());
            if (System.nanoTime() >= nextReport) {
                System.out.println(report("progress", start, threads, selfTest));
                nextReport += reportSeconds * 1000000000L;
            }
        } while (!selfTest && System.nanoTime() < end);
        System.out.println(report("summary", start, threads, selfTest));
        long failed = 0;
        for (long f : FAILURES) {
            failed += f;
        }
        System.exit(failed == 0 ? 0 : 1);
    }

    private static void runPhase(int index, boolean ok) {
        ROUNDS[index]++;
        if (!ok) {
            FAILURES[index]++;
            System.out.println("{\"event\":\"mismatch\",\"phase\":\"" + PHASES[index]
                + "\",\"round\":" + ROUNDS[index] + "}");
        }
    }

    private static String report(String event, long start, int threads, boolean selfTest) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"event\":\"").append(event).append("\",\"self_test\":").append(selfTest);
        sb.append(",\"elapsed_s\":").append((System.nanoTime() - start) / 1000000000L);
        sb.append(",\"java_version\":\"").append(System.getProperty("java.version")).append('"');
        sb.append(",\"os_arch\":\"").append(System.getProperty("os.arch")).append('"');
        sb.append(",\"threads\":").append(threads);
        for (int i = 0; i < PHASES.length; i++) {
            sb.append(",\"").append(PHASES[i]).append("_rounds\":").append(ROUNDS[i]);
            sb.append(",\"").append(PHASES[i]).append("_failures\":").append(FAILURES[i]);
        }
        return sb.append('}').toString();
    }

    // ---- phases -------------------------------------------------------------------------------

    private static final byte[] KEY = new byte[16];
    private static final byte[] IV = new byte[12];
    private static final byte[] PLAIN = new byte[64 * 1024];

    static {
        Random r = new Random(42);
        r.nextBytes(KEY);
        r.nextBytes(IV);
        r.nextBytes(PLAIN);
    }

    /** AES-128/GCM round trip of 64 KiB with a fixed key; the tag must verify. */
    static boolean aesGcm() throws GeneralSecurityException {
        SecretKeySpec key = new SecretKeySpec(KEY, "AES");
        Cipher enc = Cipher.getInstance("AES/GCM/NoPadding");
        enc.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, IV));
        byte[] ct = enc.doFinal(PLAIN);
        Cipher dec = Cipher.getInstance("AES/GCM/NoPadding");
        dec.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, IV));
        return Arrays.equals(PLAIN, dec.doFinal(ct));
    }

    /** SHA-256 of 1,000,000 times 'a' (FIPS 180-2 test vector). */
    static boolean sha256() throws GeneralSecurityException {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] block = new byte[1000];
        Arrays.fill(block, (byte) 'a');
        for (int i = 0; i < 1000; i++) {
            md.update(block);
        }
        return "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0".equals(hex(md.digest()));
    }

    /** CRC-32 of "123456789" is 0xCBF43926; also compare 64 KiB against a table-free CRC. */
    static boolean crc32() {
        CRC32 c = new CRC32();
        c.update("123456789".getBytes(StandardCharsets.US_ASCII));
        if (c.getValue() != 0xCBF43926L) {
            return false;
        }
        CRC32 big = new CRC32();
        big.update(PLAIN, 0, PLAIN.length);
        return big.getValue() == bitwiseCrc32(PLAIN);
    }

    static long bitwiseCrc32(byte[] data) {
        int crc = 0xFFFFFFFF;
        for (byte b : data) {
            crc ^= b & 0xFF;
            for (int k = 0; k < 8; k++) {
                crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
            }
        }
        return (~crc) & 0xFFFFFFFFL;
    }

    private static final BigInteger BASE = new BigInteger(1, Arrays.copyOf(PLAIN, 256));
    private static final BigInteger MOD = new BigInteger(1, Arrays.copyOfRange(PLAIN, 256, 512)).setBit(0);
    private static final BigInteger EXP = BigInteger.valueOf(65537);

    /** BigInteger.modPow (Montgomery intrinsics on some JDKs) against square-and-multiply. */
    static boolean modPow() {
        BigInteger expected = BigInteger.ONE;
        BigInteger b = BASE.mod(MOD);
        for (int i = EXP.bitLength() - 1; i >= 0; i--) {
            expected = expected.multiply(expected).mod(MOD);
            if (EXP.testBit(i)) {
                expected = expected.multiply(b).mod(MOD);
            }
        }
        return BASE.modPow(EXP, MOD).equals(expected);
    }

    private static final Pattern KV = Pattern.compile("([a-z]+)=([0-9]+);");

    /** Regex and StringBuilder: build 1000 key=value pairs, parse them back and sum. */
    static boolean regex() {
        StringBuilder sb = new StringBuilder();
        long expected = 0;
        for (int i = 0; i < 1000; i++) {
            sb.append("key").append((char) ('a' + i % 26)).append('=').append(i).append(';');
            expected += i;
        }
        Matcher m = KV.matcher(sb);
        long sum = 0;
        int count = 0;
        while (m.find()) {
            sum += Long.parseLong(m.group(2));
            count++;
        }
        return count == 1000 && sum == expected;
    }

    /** Threads increment a shared AtomicLong and ConcurrentHashMap counters; totals must match. */
    static boolean concurrent(int threads, final int perThread) throws InterruptedException {
        final AtomicLong counter = new AtomicLong();
        final ConcurrentHashMap<Integer, AtomicLong> map = new ConcurrentHashMap<Integer, AtomicLong>();
        Thread[] ts = new Thread[threads];
        for (int t = 0; t < threads; t++) {
            final int seed = t;
            ts[t] = new Thread(new Runnable() {
                @Override
                public void run() {
                    for (int i = 0; i < perThread; i++) {
                        counter.incrementAndGet();
                        Integer k = (i + seed) & 63;
                        AtomicLong v = map.get(k);
                        if (v == null) {
                            AtomicLong n = new AtomicLong();
                            v = map.putIfAbsent(k, n);
                            if (v == null) {
                                v = n;
                            }
                        }
                        v.incrementAndGet();
                    }
                }
            });
            ts[t].start();
        }
        for (Thread t : ts) {
            t.join();
        }
        long total = 0;
        for (AtomicLong v : map.values()) {
            total += v.get();
        }
        long expected = (long) threads * perThread;
        return counter.get() == expected && total == expected;
    }

    /**
     * System.arraycopy between Object[] and String[]: the copy into String[] needs a per-element
     * type check, and an Integer in the source must raise ArrayStoreException after copying the
     * elements before it.
     */
    static boolean arraycopy() {
        int n = 512;
        String[] strings = new String[n];
        for (int i = 0; i < n; i++) {
            strings[i] = Integer.toString(i);
        }
        Object[] objects = new Object[n];
        System.arraycopy(strings, 0, objects, 0, n);
        String[] back = new String[n];
        System.arraycopy(objects, 0, back, 0, n);
        if (!Arrays.equals(strings, back)) {
            return false;
        }
        Object[] mixed = Arrays.copyOf(objects, n);
        int bad = 300;
        mixed[bad] = Integer.valueOf(bad);
        String[] target = new String[n];
        try {
            System.arraycopy(mixed, 0, target, 0, n);
            return false;
        } catch (ArrayStoreException expected) {
            for (int i = 0; i < n; i++) {
                Object want = i < bad ? strings[i] : null;
                if (want == null ? target[i] != null : !want.equals(target[i])) {
                    return false;
                }
            }
            return true;
        }
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) {
            sb.append(String.format("%02x", x & 0xFF));
        }
        return sb.toString();
    }
}

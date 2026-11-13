/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

import java.lang.reflect.Field;
import java.nio.ByteOrder;

/**
 * Checks the address pattern of JDK-8267689 ("[8u] [aarch64] Crash due to bad shift in
 * indirect addressing mode", Corretto 8 issue #302): a sun.misc.Unsafe access whose address is
 * {@code base + (index << shift) + offset} where the shift does not match the access size,
 * for example a 4-byte read with a shift of 1. AArch64 loads with a scaled register index
 * can only shift by log2(access size); an affected C2 matcher still selects that addressing
 * mode, so the compiled code reads from a different address than the interpreter.
 *
 * <p>The program fills a byte array with random data, precomputes the expected value of every
 * read from the bytes, then reads the same values in hot loops through Unsafe until the time
 * is up, so C2 compiles the loops. It counts reads that differ from the expected value and
 * prints one JSON line per variant and a summary. Exit code 1 means at least one mismatch.
 * Run it once normally and once with -Xint as a control.
 *
 * <p>Usage: {@code java UnsafeShiftCheck [--seconds N] [--self-test]}.
 */
public final class UnsafeShiftCheck {

    private static final sun.misc.Unsafe U = unsafe();
    private static final long BASE = U.arrayBaseOffset(byte[].class);
    private static final int N = 4096;
    private static final byte[] DATA = new byte[N * 8 + 64];
    private static final boolean LITTLE = ByteOrder.nativeOrder() == ByteOrder.LITTLE_ENDIAN;

    // Expected values per variant, computed from the bytes without Unsafe.
    private static final int[] INT_SHIFT1 = new int[N];
    private static final int[] INT_SHIFT2 = new int[N];
    private static final int[] INT_SHIFT3 = new int[N];
    private static final long[] LONG_SHIFT2 = new long[N];
    private static final short[] SHORT_SHIFT2 = new short[N];

    private static final String[] VARIANTS = {
        "int_shift1_i2l", "int_shift1_long_index", "int_shift3_i2l", "long_shift2_i2l",
        "short_shift2_i2l", "int_shift2_control",
    };
    private static final long[] READS = new long[VARIANTS.length];
    private static final long[] MISMATCHES = new long[VARIANTS.length];
    private static final long[] FIRST_BAD = new long[VARIANTS.length];

    private UnsafeShiftCheck() {
    }

    public static void main(String[] args) {
        long seconds = 60;
        boolean selfTest = false;
        for (int i = 0; i < args.length; i++) {
            if ("--self-test".equals(args[i])) {
                selfTest = true;
            } else if (i + 1 < args.length && "--seconds".equals(args[i])) {
                seconds = Long.parseLong(args[++i]);
            } else {
                System.err.println("usage: java UnsafeShiftCheck [--seconds N] [--self-test]");
                System.exit(2);
            }
        }
        java.util.Random r = new java.util.Random(8267689L);
        r.nextBytes(DATA);
        for (int i = 0; i < N; i++) {
            INT_SHIFT1[i] = (int) bytes(i << 1, 4);
            INT_SHIFT2[i] = (int) bytes(i << 2, 4);
            INT_SHIFT3[i] = (int) bytes(i << 3, 4);
            LONG_SHIFT2[i] = bytes(i << 2, 8);
            SHORT_SHIFT2[i] = (short) bytes(i << 2, 2);
        }
        java.util.Arrays.fill(FIRST_BAD, -1);
        long start = System.nanoTime();
        long end = start + seconds * 1000000000L;
        long passes = 0;
        do {
            check(0, intShift1I2L());
            check(1, intShift1LongIndex());
            check(2, intShift3I2L());
            check(3, longShift2I2L());
            check(4, shortShift2I2L());
            check(5, intShift2Control());
            passes++;
        } while (!selfTest && System.nanoTime() < end);
        long total = 0;
        for (int v = 0; v < VARIANTS.length; v++) {
            System.out.println("{\"event\":\"variant\",\"variant\":\"" + VARIANTS[v] + "\",\"reads\":"
                + READS[v] + ",\"mismatches\":" + MISMATCHES[v] + ",\"first_bad_index\":" + FIRST_BAD[v] + "}");
            total += MISMATCHES[v];
        }
        System.out.println("{\"event\":\"summary\",\"self_test\":" + selfTest + ",\"passes\":" + passes
            + ",\"elapsed_ms\":" + (System.nanoTime() - start) / 1000000L + ",\"mismatches\":" + total
            + ",\"java_version\":\"" + System.getProperty("java.version") + "\",\"os_arch\":\""
            + System.getProperty("os.arch") + "\",\"vm_info\":\"" + System.getProperty("java.vm.info") + "\"}");
        System.exit(total == 0 ? 0 : 1);
    }

    /** check VARIANT RESULT: RESULT is (mismatches << 20) | (first bad index + 1). */
    private static void check(int v, long result) {
        READS[v] += N;
        long bad = result >>> 20;
        if (bad > 0) {
            MISMATCHES[v] += bad;
            if (FIRST_BAD[v] < 0) {
                FIRST_BAD[v] = (result & 0xFFFFF) - 1;
            }
        }
    }

    private static long encode(long bad, int firstBad) {
        return bad == 0 ? 0 : (bad << 20) | (firstBad + 1);
    }

    // Each loop below is one address shape. The index is an int widened to long (ConvI2L)
    // unless the name says long_index.

    static long intShift1I2L() {
        long bad = 0;
        int first = -1;
        for (int i = 0; i < N; i++) {
            if (U.getInt(DATA, BASE + ((long) i << 1)) != INT_SHIFT1[i]) {
                bad++;
                if (first < 0) {
                    first = i;
                }
            }
        }
        return encode(bad, first);
    }

    static long intShift1LongIndex() {
        long bad = 0;
        int first = -1;
        for (long li = 0; li < N; li++) {
            if (U.getInt(DATA, BASE + (li << 1)) != INT_SHIFT1[(int) li]) {
                bad++;
                if (first < 0) {
                    first = (int) li;
                }
            }
        }
        return encode(bad, first);
    }

    static long intShift3I2L() {
        long bad = 0;
        int first = -1;
        for (int i = 0; i < N; i++) {
            if (U.getInt(DATA, BASE + ((long) i << 3)) != INT_SHIFT3[i]) {
                bad++;
                if (first < 0) {
                    first = i;
                }
            }
        }
        return encode(bad, first);
    }

    static long longShift2I2L() {
        long bad = 0;
        int first = -1;
        for (int i = 0; i < N; i++) {
            if (U.getLong(DATA, BASE + ((long) i << 2)) != LONG_SHIFT2[i]) {
                bad++;
                if (first < 0) {
                    first = i;
                }
            }
        }
        return encode(bad, first);
    }

    static long shortShift2I2L() {
        long bad = 0;
        int first = -1;
        for (int i = 0; i < N; i++) {
            if (U.getShort(DATA, BASE + ((long) i << 2)) != SHORT_SHIFT2[i]) {
                bad++;
                if (first < 0) {
                    first = i;
                }
            }
        }
        return encode(bad, first);
    }

    /** Shift matches the access size (4 bytes, shift 2): correct on every JDK. */
    static long intShift2Control() {
        long bad = 0;
        int first = -1;
        for (int i = 0; i < N; i++) {
            if (U.getInt(DATA, BASE + ((long) i << 2)) != INT_SHIFT2[i]) {
                bad++;
                if (first < 0) {
                    first = i;
                }
            }
        }
        return encode(bad, first);
    }

    /** Value of size bytes at offset, assembled in native byte order. */
    private static long bytes(int offset, int size) {
        long v = 0;
        for (int k = 0; k < size; k++) {
            int idx = LITTLE ? offset + size - 1 - k : offset + k;
            v = (v << 8) | (DATA[idx] & 0xFF);
        }
        // sign-extend to the access size, as Unsafe.getInt/getShort do
        int bits = 64 - 8 * size;
        return bits == 0 ? v : (v << bits) >> bits;
    }

    private static sun.misc.Unsafe unsafe() {
        try {
            Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            return (sun.misc.Unsafe) f.get(null);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("cannot access sun.misc.Unsafe", e);
        }
    }
}

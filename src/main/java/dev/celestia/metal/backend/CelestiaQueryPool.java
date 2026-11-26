package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.commands.GpuQueryPool;
import java.util.Arrays;
import java.util.OptionalLong;

/**
 * Timestamp query pool backed by Metal submit GPU timings. Returns {@link OptionalLong#empty()} safely
 * for slots not yet resolved so F3+1 profiling never crashes.
 */
public final class CelestiaQueryPool implements GpuQueryPool {
    private final int size;
    private final long[] timestamps;
    private final boolean[] valid;
    private boolean closed;

    CelestiaQueryPool(int size) {
        this.size = Math.max(1, size);
        this.timestamps = new long[this.size];
        this.valid = new boolean[this.size];
    }

    void record(int index, long nanos) {
        if (closed || index < 0 || index >= size) return;
        timestamps[index] = nanos;
        valid[index] = true;
    }

    @Override
    public int size() {
        return size;
    }

    @Override
    public OptionalLong getValue(int index) {
        if (closed || index < 0 || index >= size || !valid[index]) {
            return OptionalLong.empty();
        }
        return OptionalLong.of(timestamps[index]);
    }

    @Override
    public OptionalLong[] getValues(int start, int count) {
        OptionalLong[] out = new OptionalLong[count];
        Arrays.fill(out, OptionalLong.empty());
        if (closed) return out;
        for (int i = 0; i < count; i++) {
            int idx = start + i;
            if (idx >= 0 && idx < size && valid[idx]) {
                out[i] = OptionalLong.of(timestamps[idx]);
            }
        }
        return out;
    }

    @Override
    public void close() {
        closed = true;
    }
}

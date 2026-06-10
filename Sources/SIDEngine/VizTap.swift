import Foundation
import os

/// A non-FIFO sample buffer for visualizers. The audio thread appends samples
/// (oldest get overwritten when full); the UI thread takes a chronological
/// snapshot of the last N samples without consuming them.
///
/// Different from `RingBuffer`: that one is a FIFO consumed by exactly one
/// reader. This one is a "peek the most recent samples" tap with a writer
/// and zero or more passive readers.
public final class VizTap: @unchecked Sendable {
    private let capacity: Int
    private var buffer: UnsafeMutablePointer<Int16>
    private var writeIdx: Int = 0
    private let lock = OSAllocatedUnfairLock()

    public init(capacity: Int = 8192) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Append `n` samples. Producer-thread side (may block briefly).
    public func append(_ src: UnsafePointer<Int16>, count n: Int) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(src, count: n)
    }

    /// Non-blocking append for the real-time audio thread. Skips the write
    /// if a reader holds the lock — dropping one viz chunk beats blocking a
    /// Core Audio callback.
    public func tryAppend(_ src: UnsafePointer<Int16>, count n: Int) {
        guard lock.lockIfAvailable() else { return }
        defer { lock.unlock() }
        appendLocked(src, count: n)
    }

    private func appendLocked(_ src: UnsafePointer<Int16>, count n: Int) {
        for i in 0..<n {
            buffer[writeIdx] = src[i]
            writeIdx = (writeIdx + 1) % capacity
        }
    }

    /// Copy the most recent `count` samples (chronological order, oldest
    /// first) into `dst`. Returns the number of samples written
    /// (<= min(count, capacity)).
    @discardableResult
    public func snapshot(into dst: UnsafeMutablePointer<Int16>, count n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let copies = min(n, capacity)
        let start = (writeIdx - copies + capacity) % capacity
        for i in 0..<copies {
            dst[i] = buffer[(start + i) % capacity]
        }
        return copies
    }

    /// Convenience for SwiftUI views: returns the last `n` samples as `[Float]`
    /// in [-1, 1] range, allocating a fresh array each call.
    public func snapshotFloats(count n: Int) -> [Float] {
        var int16 = [Int16](repeating: 0, count: n)
        let written = int16.withUnsafeMutableBufferPointer { ptr in
            snapshot(into: ptr.baseAddress!, count: n)
        }
        var out = [Float](repeating: 0, count: written)
        for i in 0..<written {
            out[i] = Float(int16[i]) / 32768.0
        }
        return out
    }
}

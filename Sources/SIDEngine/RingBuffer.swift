import Foundation
import os

/// Single-producer single-consumer Int16 ring buffer.
/// Uses an unfair lock — fine for our buffer sizes (a few thousand samples,
/// memcpy under lock takes microseconds).
public final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: UnsafeMutablePointer<Int16>
    private var writeIdx = 0
    private var readIdx = 0
    private var count = 0
    private let lock = OSAllocatedUnfairLock()

    public init(capacity: Int) {
        self.capacity = capacity
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    public var available: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    public var freeSpace: Int {
        lock.lock(); defer { lock.unlock() }
        return capacity - count
    }

    /// Writes up to `n` samples. Returns count actually written (may be less if full).
    @discardableResult
    public func write(_ src: UnsafePointer<Int16>, count n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let writable = min(n, capacity - count)
        for i in 0..<writable {
            storage[(writeIdx + i) % capacity] = src[i]
        }
        writeIdx = (writeIdx + writable) % capacity
        count += writable
        return writable
    }

    /// Reads up to `n` samples. Returns count actually read (may be less if empty).
    @discardableResult
    public func read(_ dst: UnsafeMutablePointer<Int16>, count n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let readable = min(n, count)
        for i in 0..<readable {
            dst[i] = storage[(readIdx + i) % capacity]
        }
        readIdx = (readIdx + readable) % capacity
        count -= readable
        return readable
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        writeIdx = 0
        readIdx = 0
        count = 0
    }
}

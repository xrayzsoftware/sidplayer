import Foundation
import os

/// Single-writer / many-reader latch holding the most recent SID register image.
/// The producer thread publishes a fresh 32-byte snapshot each render chunk; UI
/// readers peek the latest without consuming it. Mirrors `VizTap`'s
/// `OSAllocatedUnfairLock` style — the payload is tiny (32 bytes) so the lock is
/// held for microseconds.
///
/// Unlike `VizTap` there's no ring: only the newest image matters for a register
/// readout, and registers change at the tune's play rate (~50 Hz), far slower
/// than the audio render rate.
public final class RegisterLatch: @unchecked Sendable {
    private var image = [UInt8](repeating: 0, count: 32)
    private let lock = OSAllocatedUnfairLock()

    public init() {}

    /// Producer-side publish of a fresh register image. Copies up to 32 bytes;
    /// a shorter input zero-fills the tail.
    public func publish(_ regs: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let n = min(regs.count, 32)
        for i in 0..<n { image[i] = regs[i] }
        if n < 32 { for i in n..<32 { image[i] = 0 } }
    }

    /// UI-side snapshot of the latest published image (always 32 bytes).
    public func latest() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return image
    }
}

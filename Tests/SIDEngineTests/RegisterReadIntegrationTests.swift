import XCTest
@testable import SIDEngine

/// End-to-end check that the engine's `getSidStatus` bridge returns live
/// register data during playback — the part the pure decoder tests can't cover.
final class RegisterReadIntegrationTests: XCTestCase {
    func testLiveRegisterReadAfterPlayback() throws {
        let path = "Tests/Fixtures/Commando.sid"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }

        let engine = SIDPlayerEngine()
        try engine.load(path: path)
        try engine.start(song: 1, sampleRate: 44_100)

        // Render ~0.2 s so the tune's init + a few play frames program the SID.
        var buf = [Int16](repeating: 0, count: 8820)
        _ = buf.withUnsafeMutableBufferPointer {
            engine.render(into: $0.baseAddress!, count: $0.count)
        }

        let image = try XCTUnwrap(engine.readRegisters(sid: 0), "chip 0 must exist")
        let regs = SIDRegisters(image: image)
        // Effectively every SID tune writes the master volume during init, so a
        // non-zero value proves init ran and getSidStatus reflects it.
        XCTAssertGreaterThan(regs.volume, 0, "init should have written the volume register")

        // A single-SID tune has no second chip → getSidStatus returns false.
        XCTAssertNil(engine.readRegisters(sid: 1))
    }

    /// Exercises the reSIDfp engine and the builder-swap path (reSIDfp →
    /// SIDLite on reload) that frees the previous builder — a use-after-free
    /// this bridge has historically been prone to. Must render cleanly both
    /// before and after the swap.
    func testReSIDfpEngineAndBuilderSwap() throws {
        let path = "Tests/Fixtures/Commando.sid"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }

        let engine = SIDPlayerEngine()
        var buf = [Int16](repeating: 0, count: 4410)
        // Render ~0.5 s and report both that init ran (volume register set) and
        // that the engine emitted non-silent PCM — i.e. it actually produces
        // audio, not just plausible register state.
        func renderHalfSecond() -> (volume: UInt8, peak: Int16) {
            var peak: Int16 = 0
            for _ in 0..<5 {
                _ = buf.withUnsafeMutableBufferPointer {
                    engine.render(into: $0.baseAddress!, count: $0.count)
                }
                for s in buf where abs(Int(s)) > Int(peak) { peak = Int16(abs(Int(s))) }
            }
            return (SIDRegisters(image: engine.readRegisters(sid: 0) ?? []).volume, peak)
        }

        var cfg = EmulationConfig()
        cfg.engine = .residfp
        cfg.filter6581Curve = 0.7
        engine.applyConfig(cfg)
        try engine.load(path: path)
        try engine.start(song: 1, sampleRate: 44_100)
        let fp = renderHalfSecond()             // reSIDfp
        XCTAssertGreaterThan(fp.volume, 0)
        XCTAssertGreaterThan(fp.peak, 0, "reSIDfp produced silence")

        cfg.engine = .sidlite
        engine.applyConfig(cfg)
        try engine.start(song: 1, sampleRate: 44_100)   // swap frees the reSIDfp builder
        let lite = renderHalfSecond()           // SIDLite after swap — must not crash
        XCTAssertGreaterThan(lite.volume, 0)
        XCTAssertGreaterThan(lite.peak, 0, "SIDLite produced silence after swap")
    }
}

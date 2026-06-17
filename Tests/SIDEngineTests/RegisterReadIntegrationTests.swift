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
}

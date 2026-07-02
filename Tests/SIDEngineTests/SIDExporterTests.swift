import XCTest
@testable import SIDEngine

/// Byte-level tests for the hand-rolled RIFF/WAV header, plus an end-to-end
/// render against the Commando fixture. The header layout has no other
/// verification — a wrong chunk size or byte rate silently produces WAVs some
/// players reject.
final class SIDExporterTests: XCTestCase {

    func testWAVHeaderBytes() {
        let bytes = [UInt8](sidWAVHeader(sampleRate: 44_100,
                                         dataBytes: 1_000,
                                         fileBytes: 1_036))
        XCTAssertEqual(bytes.count, 44, "canonical PCM WAV header is 44 bytes")

        func le32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at+1]) << 8
                | UInt32(bytes[at+2]) << 16 | UInt32(bytes[at+3]) << 24
        }
        func le16(_ at: Int) -> UInt16 {
            UInt16(bytes[at]) | UInt16(bytes[at+1]) << 8
        }

        XCTAssertEqual(Array(bytes[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(le32(4), 1_036, "RIFF size = file bytes minus 8-byte descriptor")
        XCTAssertEqual(Array(bytes[8..<12]), Array("WAVE".utf8))
        XCTAssertEqual(Array(bytes[12..<16]), Array("fmt ".utf8))
        XCTAssertEqual(le32(16), 16, "fmt payload size")
        XCTAssertEqual(le16(20), 1, "format = PCM")
        XCTAssertEqual(le16(22), 1, "mono")
        XCTAssertEqual(le32(24), 44_100, "sample rate")
        XCTAssertEqual(le32(28), 88_200, "byte rate = SR × 1 ch × 2 bytes")
        XCTAssertEqual(le16(32), 2, "block align")
        XCTAssertEqual(le16(34), 16, "bits per sample")
        XCTAssertEqual(Array(bytes[36..<40]), Array("data".utf8))
        XCTAssertEqual(le32(40), 1_000, "data chunk size")
    }

    func testExportFixtureProducesExactLengthWAV() throws {
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/Commando.sid")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commando-export-\(getpid()).wav")
        defer { try? FileManager.default.removeItem(at: dest) }

        try exportSIDToWAV(path: fixture.path, song: 1, durationMs: 1000,
                           sampleRate: 44_100, config: EmulationConfig(), to: dest)

        let bytes = [UInt8](try Data(contentsOf: dest))
        XCTAssertEqual(Array(bytes[0..<4]), Array("RIFF".utf8))
        // 1 s mono 16-bit at 44.1 kHz: the header sizes and the actual file
        // length must all agree — a mismatch means the header-patch logic broke.
        let dataBytes = 44_100 * 2
        XCTAssertEqual(bytes.count, 44 + dataBytes)
        func le32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at+1]) << 8
                | Int(bytes[at+2]) << 16 | Int(bytes[at+3]) << 24
        }
        XCTAssertEqual(le32(40), dataBytes, "data chunk size matches rendered PCM")
        XCTAssertEqual(le32(4), dataBytes + 36, "RIFF size consistent with data size")
        // A real tune must not be all-silence.
        XCTAssertTrue(bytes[44...].contains { $0 != 0 }, "rendered PCM should be non-silent")
    }
}

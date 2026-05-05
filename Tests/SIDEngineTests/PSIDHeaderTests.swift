import XCTest
@testable import SIDEngine

final class PSIDHeaderTests: XCTestCase {
    /// Minimal PSID v2 header constructed from the real Commando.sid layout
    /// captured in `xxd Tests/Fixtures/Commando.sid` during Phase 2 design.
    /// 124-byte v2 header: "PSID", v=2, dataOffset=0x7C, songs=19, flags=0x14
    /// (PAL + 6581), title="Commando", author="Rob Hubbard", year="1985 Elite".
    private func makeCommandoHeader() -> Data {
        var d = Data(count: 0x7C)
        d.replaceSubrange(0..<4, with: "PSID".data(using: .ascii)!)
        d.beWriteUInt16(at: 0x04, 2)         // version
        d.beWriteUInt16(at: 0x06, 0x7C)      // dataOffset
        d.beWriteUInt16(at: 0x08, 0)         // loadAddress (embedded)
        d.beWriteUInt16(at: 0x0A, 0x5FB2)    // initAddress
        d.beWriteUInt16(at: 0x0C, 0x5012)    // playAddress
        d.beWriteUInt16(at: 0x0E, 19)        // songs
        d.beWriteUInt16(at: 0x10, 1)         // startSong
        d.beWriteUInt32(at: 0x12, 0)         // speed bitmap
        d.writeAscii(at: 0x16, length: 32, "Commando")
        d.writeAscii(at: 0x36, length: 32, "Rob Hubbard")
        d.writeAscii(at: 0x56, length: 32, "1985 Elite")
        d.beWriteUInt16(at: 0x76, 0x0014)    // flags: bit2=PAL, bit4=6581
        d[0x78] = 0
        d[0x79] = 0
        d[0x7A] = 0
        d[0x7B] = 0
        return d
    }

    func testParsesCommandoHeader() throws {
        let h = try PSIDHeader(data: makeCommandoHeader())
        XCTAssertEqual(h.format, .psid)
        XCTAssertEqual(h.version, 2)
        XCTAssertEqual(h.dataOffset, 0x7C)
        XCTAssertEqual(h.loadAddress, 0)
        XCTAssertEqual(h.initAddress, 0x5FB2)
        XCTAssertEqual(h.playAddress, 0x5012)
        XCTAssertEqual(h.songs, 19)
        XCTAssertEqual(h.startSong, 1)
        XCTAssertEqual(h.title, "Commando")
        XCTAssertEqual(h.author, "Rob Hubbard")
        XCTAssertEqual(h.released, "1985 Elite")
        XCTAssertEqual(h.flags, 0x0014)
        XCTAssertEqual(h.clock, .pal)
        XCTAssertEqual(h.model, .mos6581)
    }

    func testRejectsTooShortFile() {
        XCTAssertThrowsError(try PSIDHeader(data: Data(count: 0x40))) { err in
            guard case PSIDHeader.ParseError.fileTooShort = err else {
                return XCTFail("expected fileTooShort, got \(err)")
            }
        }
    }

    func testRejectsBadMagic() {
        var d = makeCommandoHeader()
        d.replaceSubrange(0..<4, with: "XXXX".data(using: .ascii)!)
        XCTAssertThrowsError(try PSIDHeader(data: d)) { err in
            guard case PSIDHeader.ParseError.badMagic = err else {
                return XCTFail("expected badMagic, got \(err)")
            }
        }
    }

    func testRSIDMagicAccepted() throws {
        var d = makeCommandoHeader()
        d.replaceSubrange(0..<4, with: "RSID".data(using: .ascii)!)
        let h = try PSIDHeader(data: d)
        XCTAssertEqual(h.format, .rsid)
    }

    func testReadsRealCommandoFixtureIfPresent() throws {
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/Commando.sid")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }
        let h = try PSIDHeader(contentsOf: fixture)
        XCTAssertEqual(h.title, "Commando")
        XCTAssertEqual(h.author, "Rob Hubbard")
        XCTAssertEqual(h.songs, 19)
        XCTAssertEqual(h.clock, .pal)
        XCTAssertEqual(h.model, .mos6581)
    }
}

private extension Data {
    mutating func beWriteUInt16(at offset: Int, _ v: UInt16) {
        self[offset]     = UInt8((v >> 8) & 0xFF)
        self[offset + 1] = UInt8(v & 0xFF)
    }
    mutating func beWriteUInt32(at offset: Int, _ v: UInt32) {
        self[offset]     = UInt8((v >> 24) & 0xFF)
        self[offset + 1] = UInt8((v >> 16) & 0xFF)
        self[offset + 2] = UInt8((v >> 8) & 0xFF)
        self[offset + 3] = UInt8(v & 0xFF)
    }
    mutating func writeAscii(at offset: Int, length: Int, _ s: String) {
        let bytes = [UInt8](s.utf8.prefix(length))
        for i in 0..<length {
            self[offset + i] = i < bytes.count ? bytes[i] : 0
        }
    }
}

import XCTest
@testable import SIDEngine

final class SonglengthsTests: XCTestCase {
    private let sample = """
    ; HVSC Songlengths.md5
    ; /MUSICIANS/H/Hubbard_Rob/Commando.sid
    6d019ecba831a9f853675aac29a61c10=3:05 0:55 1:01 0:34 0:14
    ; /MUSICIANS/F/Fractional_Test.sid
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=1:23.456 0:00.500
    ; bad line below should be skipped
    notamd5=1:00
    """

    func testParsesBasicEntries() {
        let s = Songlengths(text: sample)
        let lens = s.lengthsByMD5["6d019ecba831a9f853675aac29a61c10"]
        XCTAssertEqual(lens, [185_000, 55_000, 61_000, 34_000, 14_000])
    }

    func testParsesFractionalSeconds() {
        let s = Songlengths(text: sample)
        let lens = s.lengthsByMD5["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        XCTAssertEqual(lens, [83_456, 500])
    }

    func testSkipsCommentsAndBadLines() {
        let s = Songlengths(text: sample)
        XCTAssertNil(s.lengthsByMD5["notamd5"])
        XCTAssertEqual(s.lengthsByMD5.count, 2)
    }

    func testLengthLookup() {
        let s = Songlengths(text: sample)
        XCTAssertEqual(s.length(md5: "6d019ecba831a9f853675aac29a61c10", subtune: 0), 185_000)
        XCTAssertEqual(s.length(md5: "6D019ECBA831A9F853675AAC29A61C10", subtune: 2), 61_000) // case-insensitive
        XCTAssertNil(s.length(md5: "6d019ecba831a9f853675aac29a61c10", subtune: 99))
        XCTAssertNil(s.length(md5: "missing", subtune: 0))
    }

    func testHandlesCRLFLineEndings() {
        // Real HVSC Songlengths.md5 ships with Windows-style CRLF endings.
        // In Swift's Character model CRLF is one grapheme — splitting on \n
        // alone matches nothing.
        let crlf = "[Database]\r\n; /A.sid\r\n6d019ecba831a9f853675aac29a61c10=3:05\r\n; /B.sid\r\nabcdef0123456789abcdef0123456789=1:00\r\n"
        let s = Songlengths(text: crlf)
        XCTAssertEqual(s.lengthsByMD5.count, 2)
        XCTAssertEqual(s.lengthsByMD5["6d019ecba831a9f853675aac29a61c10"], [185_000])
        XCTAssertEqual(s.lengthsByMD5["abcdef0123456789abcdef0123456789"], [60_000])
    }

    func testIgnoresDatabaseHeader() {
        let withHeader = "[Database]\n6d019ecba831a9f853675aac29a61c10=3:05\n"
        let s = Songlengths(text: withHeader)
        XCTAssertEqual(s.lengthsByMD5.count, 1)
    }

    func testParseDurationCases() {
        XCTAssertEqual(Songlengths.parseDuration("3:05"),       185_000)
        XCTAssertEqual(Songlengths.parseDuration("12:34"),      754_000)
        XCTAssertEqual(Songlengths.parseDuration("0:00.001"),   1)
        XCTAssertEqual(Songlengths.parseDuration("1:00.5"),     60_500)
        XCTAssertNil(Songlengths.parseDuration("garbage"))
        XCTAssertNil(Songlengths.parseDuration("1.5"))
    }
}

import XCTest
@testable import SIDCatalog

final class HVSCIndexerTests: XCTestCase {

    /// Builds a synthetic HVSC tree in a temp dir using the gitignored Commando
    /// fixture, then indexes it end-to-end. Skips when the fixture isn't present.
    func testIndexesSyntheticHVSCTree() async throws {
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/Commando.sid")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }

        // Lay out a minimal HVSC root: <tmp>/MUSICIANS/H/Hubbard_Rob/Commando.sid
        // plus DOCUMENTS/Songlengths.md5 with one matching entry.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hvsc-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let tunePath = root.appendingPathComponent("MUSICIANS/H/Hubbard_Rob/Commando.sid")
        try fm.createDirectory(at: tunePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixture, to: tunePath)

        // Commando's HVSC#68+ MD5, computed via libsidplayfp in Phase 1.
        let songlengths = """
            ; HVSC fake songlengths
            ; /MUSICIANS/H/Hubbard_Rob/Commando.sid
            6d019ecba831a9f853675aac29a61c10=3:05 0:55 1:01
            """
        let docs = root.appendingPathComponent("DOCUMENTS")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try songlengths.write(to: docs.appendingPathComponent("Songlengths.md5"),
                              atomically: true, encoding: .utf8)

        let source = HVSCSource(root: root)
        try source.validate()

        let db = try CatalogDB()
        let indexer = HVSCIndexer()
        let inserted = try await indexer.reindex(source: source, into: db)

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(try db.count(), 1)

        // Hit the real metadata path: PSID parser extracted the right fields,
        // and libsidplayfp's MD5 matched the songlengths entry.
        let row = try XCTUnwrap(try db.tune(path: "MUSICIANS/H/Hubbard_Rob/Commando.sid"))
        XCTAssertEqual(row.title, "Commando")
        XCTAssertEqual(row.author, "Rob Hubbard")
        XCTAssertEqual(row.clock, "PAL")
        XCTAssertEqual(row.model, "6581")
        XCTAssertEqual(row.songs, 19)
        XCTAssertEqual(row.md5, "6d019ecba831a9f853675aac29a61c10")
        XCTAssertEqual(row.defaultLengthMs, 185_000)  // 3:05

        // Songlengths array stored.
        let lens = try db.lengths(tuneId: row.id!)
        XCTAssertEqual(lens.map(\.durationMs), [185_000, 55_000, 61_000])

        // FTS5 search reaches the row.
        let hits = try db.search("hubbard")
        XCTAssertEqual(hits.first?.id, row.id)
    }
}

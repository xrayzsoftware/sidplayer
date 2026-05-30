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

    /// Re-indexing must keep tune ids stable so playlist and play-history
    /// references (which key on tune id) survive. Regression for the old
    /// clear-and-reinsert behaviour that silently emptied both.
    func testReindexPreservesPlaylistAndHistory() async throws {
        let path = "MUSICIANS/H/Hubbard_Rob/Commando.sid"
        let root = try makeSyntheticRoot(relPaths: [path])
        defer { try? FileManager.default.removeItem(at: root) }

        let source = HVSCSource(root: root)
        let db = try CatalogDB()
        let indexer = HVSCIndexer()

        _ = try await indexer.reindex(source: source, into: db)
        let firstID = try XCTUnwrap(try db.tune(path: path)?.id)

        // User state keyed on the tune id.
        let playlist = try db.createPlaylist(name: "Mix")
        try db.addToPlaylist(playlistId: playlist.id!, tuneId: firstID)
        try db.recordPlay(tuneId: firstID)

        // Re-index the unchanged tree.
        _ = try await indexer.reindex(source: source, into: db)

        let secondID = try XCTUnwrap(try db.tune(path: path)?.id)
        XCTAssertEqual(secondID, firstID, "re-index must preserve tune ids")
        XCTAssertEqual(try db.playlistTracks(id: playlist.id!).compactMap(\.id), [firstID],
                       "playlist membership must survive a re-index")
        XCTAssertEqual(try db.recentlyPlayed().compactMap(\.id), [firstID],
                       "play history must survive a re-index")
    }

    /// A file that disappears between indexes is dropped; survivors keep their
    /// ids, and the cascaded playlist removal is re-densified so removal-by-
    /// index still targets the right row.
    func testReindexDropsRemovedFilesAndRepacksPlaylist() async throws {
        let gone = "MUSICIANS/H/Hubbard_Rob/Commando_Old.sid"
        let keep = "MUSICIANS/H/Hubbard_Rob/Commando.sid"
        let root = try makeSyntheticRoot(relPaths: [gone, keep])
        defer { try? FileManager.default.removeItem(at: root) }

        let source = HVSCSource(root: root)
        let db = try CatalogDB()
        let indexer = HVSCIndexer()

        _ = try await indexer.reindex(source: source, into: db)
        XCTAssertEqual(try db.count(), 2)
        let goneID = try XCTUnwrap(try db.tune(path: gone)?.id)
        let keepID = try XCTUnwrap(try db.tune(path: keep)?.id)

        // Playlist: removed tune at position 0, survivor at position 1.
        let pl = try db.createPlaylist(name: "Mix")
        try db.addToPlaylist(playlistId: pl.id!, tuneId: goneID)
        try db.addToPlaylist(playlistId: pl.id!, tuneId: keepID)

        // Delete one file, then re-index.
        try FileManager.default.removeItem(at: root.appendingPathComponent(gone))
        _ = try await indexer.reindex(source: source, into: db)

        XCTAssertEqual(try db.count(), 1)
        XCTAssertNil(try db.tune(path: gone), "removed file should be dropped")
        XCTAssertEqual(try db.tune(path: keep)?.id, keepID, "survivor id must be stable")
        XCTAssertEqual(try db.playlistTracks(id: pl.id!).compactMap(\.id), [keepID])

        // Survivor must have been re-packed from position 1 to position 0;
        // removing position 0 should empty the playlist. (If positions still
        // had a gap, position 0 wouldn't exist and the survivor would remain.)
        try db.removeFromPlaylist(playlistId: pl.id!, position: 0)
        XCTAssertTrue(try db.playlistTracks(id: pl.id!).isEmpty,
                      "playlist positions must be re-densified after a cascade")
    }

    /// Builds a synthetic HVSC root with the Commando fixture copied to each of
    /// `relPaths`, plus a matching DOCUMENTS/Songlengths.md5. Skips when the
    /// gitignored fixture isn't present.
    private func makeSyntheticRoot(relPaths: [String]) throws -> URL {
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/Commando.sid")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hvsc-test-\(UUID().uuidString)")
        for rel in relPaths {
            let dest = root.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: fixture, to: dest)
        }
        let songlengths = """
            ; HVSC fake songlengths
            6d019ecba831a9f853675aac29a61c10=3:05 0:55 1:01
            """
        let docs = root.appendingPathComponent("DOCUMENTS")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try songlengths.write(to: docs.appendingPathComponent("Songlengths.md5"),
                              atomically: true, encoding: .utf8)
        return root
    }
}

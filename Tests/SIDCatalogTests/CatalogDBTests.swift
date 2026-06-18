import XCTest
@testable import SIDCatalog

final class CatalogDBTests: XCTestCase {

    private func makeRow(
        path: String,
        title: String?,
        author: String?,
        startSong: Int = 1,
        songs: Int = 1
    ) -> TuneRow {
        TuneRow(
            path: path,
            md5: "0123456789abcdef0123456789abcdef",
            format: "PSID",
            version: 2,
            title: title,
            author: author,
            released: "1985",
            songs: songs,
            startSong: startSong,
            clock: "PAL",
            model: "6581",
            sidChips: 1,
            defaultLengthMs: nil
        )
    }

    func testEmptyDBStartsAtZero() throws {
        let db = try CatalogDB()
        XCTAssertEqual(try db.count(), 0)
    }

    func testInsertAndFetch() throws {
        let db = try CatalogDB()
        let id = try db.insert(
            tune: makeRow(path: "MUSICIANS/H/Hubbard_Rob/Commando.sid",
                          title: "Commando",
                          author: "Rob Hubbard",
                          startSong: 1,
                          songs: 3),
            lengths: [185_000, 55_000, 61_000]
        )
        XCTAssertEqual(try db.count(), 1)

        let fetched = try db.tune(id: id)
        XCTAssertEqual(fetched?.title, "Commando")
        XCTAssertEqual(fetched?.author, "Rob Hubbard")

        // defaultLengthMs is denormalized from the lengths array at startSong-1.
        XCTAssertEqual(fetched?.defaultLengthMs, 185_000)

        let lens = try db.lengths(tuneId: id)
        XCTAssertEqual(lens.map(\.durationMs), [185_000, 55_000, 61_000])
    }

    func testPlayCountsRankByCumulativePlays() throws {
        let db = try CatalogDB()
        let a = try db.insert(tune: makeRow(path: "a.sid", title: "A", author: "X"), lengths: [1000])
        let b = try db.insert(tune: makeRow(path: "b.sid", title: "B", author: "Y"), lengths: [1000])

        // B played 3×, A once → B ranks first with the right count.
        try db.recordPlay(tuneId: a)
        for _ in 0..<3 { try db.recordPlay(tuneId: b) }

        let top = try db.mostPlayed(limit: 10)
        XCTAssertEqual(top.map(\.tune.id), [b, a])
        XCTAssertEqual(top.map(\.count), [3, 1])
    }

    func testPlayCountSurvivesHistoryPrune() throws {
        let db = try CatalogDB()
        let id = try db.insert(tune: makeRow(path: "p.sid", title: "P", author: "Z"), lengths: [1000])
        // Exceed the 1000-row history prune; the cumulative count must not be
        // capped by it (the whole reason play_counts is a separate table).
        for _ in 0..<1005 { try db.recordPlay(tuneId: id) }
        XCTAssertEqual(try db.mostPlayed().first?.count, 1005)
    }

    func testDefaultLengthUsesStartSong() throws {
        let db = try CatalogDB()
        let id = try db.insert(
            tune: makeRow(path: "x.sid", title: "X", author: "A", startSong: 2, songs: 3),
            lengths: [10_000, 20_000, 30_000]
        )
        XCTAssertEqual(try db.tune(id: id)?.defaultLengthMs, 20_000)
    }

    func testSearchByAuthor() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "a.sid", title: "Commando", author: "Rob Hubbard"), lengths: [])
        _ = try db.insert(tune: makeRow(path: "b.sid", title: "Monty",     author: "Rob Hubbard"), lengths: [])
        _ = try db.insert(tune: makeRow(path: "c.sid", title: "Wizball",   author: "Martin Galway"), lengths: [])

        let hubbard = try db.search("hubbard")
        XCTAssertEqual(hubbard.count, 2)
        XCTAssertEqual(Set(hubbard.compactMap { $0.title }), ["Commando", "Monty"])
    }

    func testSearchByTitlePrefix() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "a.sid", title: "Commando",      author: "Rob"), lengths: [])
        _ = try db.insert(tune: makeRow(path: "b.sid", title: "Comic Bakery",  author: "Rob"), lengths: [])
        _ = try db.insert(tune: makeRow(path: "c.sid", title: "Monty",         author: "Rob"), lengths: [])

        let com = try db.search("com")
        XCTAssertEqual(com.count, 2)
    }

    /// Bare uppercase NOT/AND/OR are FTS5 query operators — a user typing one
    /// as a search term must get (empty) results, not a thrown syntax error.
    func testSearchWithFTS5OperatorWordsDoesNotThrow() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "a.sid", title: "Not Even Close", author: "Rob"), lengths: [])

        for q in ["NOT", "AND", "OR", "NOT even"] {
            XCTAssertNoThrow(try db.search(q), "query \"\(q)\" must not be parsed as an FTS5 operator")
        }
        // Case-folded matching still works.
        XCTAssertEqual(try db.search("NOT").first?.title, "Not Even Close")
    }

    func testEmptyQueryReturnsAllRowsLimited() throws {
        let db = try CatalogDB()
        for i in 0..<5 {
            _ = try db.insert(tune: makeRow(path: "t\(i).sid", title: "T\(i)", author: "A"), lengths: [])
        }
        let rows = try db.search("", limit: 3)
        XCTAssertEqual(rows.count, 3)
    }

    func testClearRemovesAll() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "a.sid", title: "Commando", author: "Rob"), lengths: [10_000])
        try db.clear()
        XCTAssertEqual(try db.count(), 0)
    }

    func testBatchUpsertInsertsAndPreservesIDs() throws {
        let db = try CatalogDB()
        let ids = try db.upsert(tunes: [
            (tune: makeRow(path: "a.sid", title: "A", author: "X"), lengths: [10_000]),
            (tune: makeRow(path: "b.sid", title: "B", author: "Y"), lengths: [20_000, 30_000]),
        ])
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try db.count(), 2)
        XCTAssertEqual(try db.tune(id: ids[0])?.title, "A")
        XCTAssertEqual(try db.lengths(tuneId: ids[1]).map(\.durationMs), [20_000, 30_000])

        // Re-upserting an existing path updates in place: same id, replaced lengths.
        let ids2 = try db.upsert(tunes: [
            (tune: makeRow(path: "a.sid", title: "A2", author: "X"), lengths: [11_000]),
        ])
        XCTAssertEqual(ids2, [ids[0]], "upsert must preserve the id for an existing path")
        XCTAssertEqual(try db.count(), 2)
        XCTAssertEqual(try db.tune(id: ids[0])?.title, "A2")
        XCTAssertEqual(try db.lengths(tuneId: ids[0]).map(\.durationMs), [11_000])
    }

    func testDuplicatePathRejected() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "dup.sid", title: "A", author: "X"), lengths: [])
        XCTAssertThrowsError(try db.insert(tune: makeRow(path: "dup.sid", title: "B", author: "Y"), lengths: []))
    }
}

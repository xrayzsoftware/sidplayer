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

    func testDuplicatePathRejected() throws {
        let db = try CatalogDB()
        _ = try db.insert(tune: makeRow(path: "dup.sid", title: "A", author: "X"), lengths: [])
        XCTAssertThrowsError(try db.insert(tune: makeRow(path: "dup.sid", title: "B", author: "Y"), lengths: []))
    }
}

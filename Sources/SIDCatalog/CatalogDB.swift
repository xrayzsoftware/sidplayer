import Foundation
import GRDB
import SIDEngine

// MARK: - Records

public struct TuneRow: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var path: String              // relative to HVSC root, e.g. "MUSICIANS/H/Hubbard_Rob/Commando.sid"
    public var md5: String
    public var format: String            // "PSID" / "RSID"
    public var version: Int
    public var title: String?
    public var author: String?
    public var released: String?
    public var songs: Int
    public var startSong: Int            // 1-indexed
    public var clock: String             // "PAL" / "NTSC" / "ANY" / "?"
    public var model: String             // "6581" / "8580" / "ANY" / "?"
    public var sidChips: Int
    public var defaultLengthMs: Int?     // duration of the default subtune

    public static let databaseTableName = "tunes"

    public init(
        id: Int64? = nil,
        path: String, md5: String, format: String, version: Int,
        title: String?, author: String?, released: String?,
        songs: Int, startSong: Int,
        clock: String, model: String, sidChips: Int,
        defaultLengthMs: Int?
    ) {
        self.id = id
        self.path = path
        self.md5 = md5
        self.format = format
        self.version = version
        self.title = title
        self.author = author
        self.released = released
        self.songs = songs
        self.startSong = startSong
        self.clock = clock
        self.model = model
        self.sidChips = sidChips
        self.defaultLengthMs = defaultLengthMs
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct LengthRow: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public var tuneId: Int64
    public var subtune: Int              // 0-indexed
    public var durationMs: Int

    public static let databaseTableName = "lengths"

    public init(tuneId: Int64, subtune: Int, durationMs: Int) {
        self.tuneId = tuneId
        self.subtune = subtune
        self.durationMs = durationMs
    }
}

// MARK: - DB

public final class CatalogDB {
    public let dbWriter: any DatabaseWriter

    /// Open an on-disk catalog at `url`. Runs migrations.
    public convenience init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try self.init(dbWriter: pool)
    }

    /// In-memory catalog (for tests).
    public convenience init() throws {
        let queue = try DatabaseQueue()
        try self.init(dbWriter: queue)
    }

    public init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    // MARK: Migrations

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "tunes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path",            .text).notNull().unique()
                t.column("md5",             .text).notNull().indexed()
                t.column("format",          .text).notNull()
                t.column("version",         .integer).notNull()
                t.column("title",           .text)
                t.column("author",          .text)
                t.column("released",        .text)
                t.column("songs",           .integer).notNull()
                t.column("startSong",       .integer).notNull()
                t.column("clock",           .text).notNull()
                t.column("model",           .text).notNull()
                t.column("sidChips",        .integer).notNull().defaults(to: 1)
                t.column("defaultLengthMs", .integer)
            }

            try db.create(table: "lengths") { t in
                t.column("tuneId",      .integer).notNull()
                    .references("tunes", onDelete: .cascade)
                t.column("subtune",     .integer).notNull()
                t.column("durationMs",  .integer).notNull()
                t.primaryKey(["tuneId", "subtune"])
            }

            // FTS5 virtual table for the catalog filter box. Keeps content in
            // sync with `tunes` via SQL triggers below.
            try db.create(virtualTable: "tunes_fts", using: FTS5()) { t in
                t.synchronize(withTable: "tunes")
                t.column("title")
                t.column("author")
                t.column("path")
                t.tokenizer = .unicode61()
            }
        }
        return m
    }

    // MARK: Queries

    public func count() throws -> Int {
        try dbWriter.read { db in try TuneRow.fetchCount(db) }
    }

    public func clear() throws {
        try dbWriter.write { db in
            try TuneRow.deleteAll(db)
        }
    }

    public func insert(tune: TuneRow, lengths: [Int]) throws -> Int64 {
        try dbWriter.write { db in
            var t = tune
            // Denormalized convenience: default subtune is 1-indexed in PSID;
            // lengths array is 0-indexed.
            let defaultIdx = max(t.startSong - 1, 0)
            if defaultIdx < lengths.count {
                t.defaultLengthMs = lengths[defaultIdx]
            }
            try t.insert(db)
            let id = t.id ?? db.lastInsertedRowID
            for (i, ms) in lengths.enumerated() {
                try LengthRow(tuneId: id, subtune: i, durationMs: ms).insert(db)
            }
            return id
        }
    }

    public func tune(id: Int64) throws -> TuneRow? {
        try dbWriter.read { db in try TuneRow.fetchOne(db, key: id) }
    }

    public func tune(path: String) throws -> TuneRow? {
        try dbWriter.read { db in
            try TuneRow.filter(Column("path") == path).fetchOne(db)
        }
    }

    public func lengths(tuneId: Int64) throws -> [LengthRow] {
        try dbWriter.read { db in
            try LengthRow
                .filter(Column("tuneId") == tuneId)
                .order(Column("subtune"))
                .fetchAll(db)
        }
    }

    /// Full-text search across title/author/path.
    /// Empty/whitespace query returns the first `limit` rows ordered by author/title.
    public func search(_ query: String, limit: Int = 200) throws -> [TuneRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.read { db in
            if q.isEmpty {
                return try TuneRow
                    .order(Column("author"), Column("title"))
                    .limit(limit)
                    .fetchAll(db)
            }
            // FTS5 prefix search: append * to each token. Strip characters that
            // would confuse the tokenizer.
            let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard !tokens.isEmpty else { return [] }
            let pattern = tokens.map { "\($0)*" }.joined(separator: " ")

            let sql = """
                SELECT tunes.*
                FROM tunes
                JOIN tunes_fts ON tunes_fts.rowid = tunes.id
                WHERE tunes_fts MATCH ?
                ORDER BY tunes.author, tunes.title
                LIMIT ?
            """
            return try TuneRow.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }
}

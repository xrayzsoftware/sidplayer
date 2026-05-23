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

public struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public static let databaseTableName = "playlists"

    public init(id: Int64? = nil, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct PlaylistTrack: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public var playlistId: Int64
    public var position: Int            // 0-indexed, dense within a playlist
    public var tuneId: Int64

    public static let databaseTableName = "playlist_tracks"

    public init(playlistId: Int64, position: Int, tuneId: Int64) {
        self.playlistId = playlistId
        self.position = position
        self.tuneId = tuneId
    }
}

public struct PlayHistoryRow: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var tuneId: Int64
    public var subtune: Int
    public var playedAt: Date

    public static let databaseTableName = "play_history"

    public init(tuneId: Int64, subtune: Int = 1, playedAt: Date = Date()) {
        self.tuneId = tuneId
        self.subtune = subtune
        self.playedAt = playedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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

        m.registerMigration("v2_playlists") { db in
            try db.create(table: "playlists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name",      .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "playlist_tracks") { t in
                t.column("playlistId", .integer).notNull()
                    .references("playlists", onDelete: .cascade)
                t.column("position",   .integer).notNull()
                t.column("tuneId",     .integer).notNull()
                    .references("tunes", onDelete: .cascade)
                t.primaryKey(["playlistId", "position"])
            }
        }
        m.registerMigration("v3_play_history") { db in
            try db.create(table: "play_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tuneId",   .integer).notNull()
                    .references("tunes", onDelete: .cascade)
                t.column("subtune",  .integer).notNull().defaults(to: 1)
                t.column("playedAt", .datetime).notNull()
            }
            try db.create(index: "play_history_playedAt",
                          on: "play_history", columns: ["playedAt"])
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

    /// Subset of `path` immediately under `prefix`, split into subdirectory
    /// names and direct file rows. `prefix` should be either empty (root)
    /// or end with no trailing slash (e.g. `"MUSICIANS/H/Hubbard_Rob"`).
    public func browse(prefix: String) throws -> (dirs: [String], tunes: [TuneRow]) {
        let p = prefix.isEmpty ? "" : prefix + "/"
        let likePattern = p + "%"
        let restStart = p.count + 1   // 1-indexed for SQLite substr()
        return try dbWriter.read { db in
            // Direct file rows: path under prefix with no further '/'.
            let tunes = try TuneRow.fetchAll(db, sql: """
                SELECT * FROM tunes
                WHERE path LIKE ?
                  AND instr(substr(path, ?), '/') = 0
                ORDER BY path
            """, arguments: [likePattern, restStart])

            // Immediate subdirectory names: first segment of the remainder
            // after prefix, for rows that have a further '/'.
            let dirs = try String.fetchAll(db, sql: """
                SELECT DISTINCT substr(path, ?, instr(substr(path, ?), '/') - 1)
                FROM tunes
                WHERE path LIKE ?
                  AND instr(substr(path, ?), '/') > 0
            """, arguments: [restStart, restStart, likePattern, restStart])

            return (dirs.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }),
                    tunes)
        }
    }

    /// Bulk fetch by IDs in a single query, preserving order of input.
    public func tunes(ids: [Int64]) throws -> [TuneRow] {
        guard !ids.isEmpty else { return [] }
        return try dbWriter.read { db in
            let rows = try TuneRow.filter(ids.contains(Column("id"))).fetchAll(db)
            // Preserve input order
            var byID: [Int64: TuneRow] = [:]
            for r in rows { if let id = r.id { byID[id] = r } }
            return ids.compactMap { byID[$0] }
        }
    }

    // MARK: Playlists

    public func playlists() throws -> [Playlist] {
        try dbWriter.read { db in
            try Playlist.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func createPlaylist(name: String) throws -> Playlist {
        try dbWriter.write { db in
            var p = Playlist(name: name, createdAt: Date())
            try p.insert(db)
            return p
        }
    }

    public func renamePlaylist(id: Int64, name: String) throws {
        _ = try dbWriter.write { db in
            try Playlist
                .filter(key: id)
                .updateAll(db, [Column("name").set(to: name)])
        }
    }

    public func deletePlaylist(id: Int64) throws {
        _ = try dbWriter.write { db in
            try Playlist.filter(key: id).deleteAll(db)
        }
    }

    public func playlistTrackCount(id: Int64) throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlistId = ?",
                arguments: [id]
            ) ?? 0
        }
    }

    /// Tunes in playlist order. Joins tunes ⨝ playlist_tracks ordered by position.
    public func playlistTracks(id: Int64) throws -> [TuneRow] {
        try dbWriter.read { db in
            try TuneRow.fetchAll(db, sql: """
                SELECT tunes.* FROM tunes
                JOIN playlist_tracks ON playlist_tracks.tuneId = tunes.id
                WHERE playlist_tracks.playlistId = ?
                ORDER BY playlist_tracks.position
            """, arguments: [id])
        }
    }

    public func addToPlaylist(playlistId: Int64, tuneId: Int64) throws {
        try dbWriter.write { db in
            let nextPos = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_tracks WHERE playlistId = ?",
                arguments: [playlistId]
            ) ?? 0
            try PlaylistTrack(
                playlistId: playlistId,
                position: nextPos,
                tuneId: tuneId
            ).insert(db)
        }
    }

    /// Removes the row at `position` and re-packs remaining positions so they
    /// stay dense (0..n-1). Composite PK (playlistId, position) means we
    /// can't just shift via UPDATE without temporary collisions, so the
    /// implementation rewrites the playlist's rows.
    public func removeFromPlaylist(playlistId: Int64, position: Int) throws {
        try dbWriter.write { db in
            let remaining = try PlaylistTrack
                .filter(Column("playlistId") == playlistId
                        && Column("position") != position)
                .order(Column("position"))
                .fetchAll(db)
            try PlaylistTrack
                .filter(Column("playlistId") == playlistId)
                .deleteAll(db)
            for (i, t) in remaining.enumerated() {
                try PlaylistTrack(playlistId: playlistId, position: i, tuneId: t.tuneId)
                    .insert(db)
            }
        }
    }

    /// Renders the playlist as an extended M3U8 referencing absolute paths
    /// under `hvscRoot`. Suitable for opening in VLC or another SID-aware
    /// player; SID Player itself doesn't read M3U.
    public func exportM3U(playlistId: Int64, hvscRoot: URL) throws -> String {
        let rows = try playlistTracks(id: playlistId)
        var out = "#EXTM3U\n"
        for r in rows {
            let title  = r.title  ?? "?"
            let author = r.author ?? "?"
            let lenSec = (r.defaultLengthMs ?? 0) / 1000
            out += "#EXTINF:\(lenSec),\(author) - \(title)\n"
            out += hvscRoot.appendingPathComponent(r.path).path + "\n"
        }
        return out
    }

    /// Structured search filters applied as SQL WHERE clauses.
    public struct SearchFilters: Sendable {
        public var model: String?       // "6581", "8580"
        public var clock: String?       // "PAL", "NTSC"
        public var yearFrom: Int?       // e.g. 1985
        public var yearTo: Int?         // e.g. 1992
        public init() {}

        var isEmpty: Bool {
            model == nil && clock == nil && yearFrom == nil && yearTo == nil
        }
    }

    /// Full-text search across title/author/path.
    /// Empty/whitespace query returns rows ordered by the given sort columns.
    /// `sortedBy` maps column names to ascending/descending; when empty the
    /// default is (author ASC, title ASC). `limit` caps the result count;
    /// pass nil for no cap.
    public func search(
        _ query: String,
        limit: Int? = nil,
        sortedBy columns: [(column: String, ascending: Bool)] = [],
        filters: SearchFilters = SearchFilters()
    ) throws -> [TuneRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderSQL = Self.orderClause(from: columns)
        let limitSQL = limit.map { " LIMIT \($0)" } ?? ""

        // Build filter fragments
        var filterParts: [String] = []
        var filterArgs: [any DatabaseValueConvertible] = []
        if let model = filters.model {
            filterParts.append("tunes.model = ?")
            filterArgs.append(model)
        }
        if let clock = filters.clock {
            filterParts.append("tunes.clock = ?")
            filterArgs.append(clock)
        }
        if let yearFrom = filters.yearFrom {
            filterParts.append("CAST(substr(tunes.released, 1, 4) AS INTEGER) >= ?")
            filterArgs.append(yearFrom)
        }
        if let yearTo = filters.yearTo {
            filterParts.append("CAST(substr(tunes.released, 1, 4) AS INTEGER) <= ?")
            filterArgs.append(yearTo)
        }

        return try dbWriter.read { db in
            if q.isEmpty {
                if filterParts.isEmpty {
                    return try TuneRow.fetchAll(db, sql:
                        "SELECT * FROM tunes ORDER BY \(orderSQL)\(limitSQL)")
                }
                let whereSQL = filterParts.joined(separator: " AND ")
                return try TuneRow.fetchAll(db, sql:
                    "SELECT * FROM tunes WHERE \(whereSQL) ORDER BY \(orderSQL)\(limitSQL)",
                    arguments: StatementArguments(filterArgs))
            }
            let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard !tokens.isEmpty else { return [] }
            let pattern = tokens.map { "\($0)*" }.joined(separator: " ")

            var allArgs: [any DatabaseValueConvertible] = [pattern]
            allArgs.append(contentsOf: filterArgs)
            let filterSQL = filterParts.isEmpty ? "" : " AND " + filterParts.joined(separator: " AND ")

            return try TuneRow.fetchAll(db, sql: """
                SELECT tunes.*
                FROM tunes
                JOIN tunes_fts ON tunes_fts.rowid = tunes.id
                WHERE tunes_fts MATCH ?\(filterSQL)
                ORDER BY \(orderSQL)\(limitSQL)
            """, arguments: StatementArguments(allArgs))
        }
    }

    // MARK: Play History

    /// Record a play event. Auto-prunes to the newest 1000 entries.
    public func recordPlay(tuneId: Int64, subtune: Int = 1) throws {
        try dbWriter.write { db in
            var row = PlayHistoryRow(tuneId: tuneId, subtune: subtune)
            try row.insert(db)
            let count = try PlayHistoryRow.fetchCount(db)
            if count > 1000 {
                try db.execute(sql: """
                    DELETE FROM play_history
                    WHERE id NOT IN (
                        SELECT id FROM play_history ORDER BY playedAt DESC LIMIT 1000
                    )
                """)
            }
        }
    }

    /// Recently played tunes, newest first, deduped by tuneId.
    public func recentlyPlayed(limit: Int = 200) throws -> [TuneRow] {
        try dbWriter.read { db in
            try TuneRow.fetchAll(db, sql: """
                SELECT tunes.* FROM tunes
                JOIN (
                    SELECT tuneId, MAX(playedAt) AS lastPlayed
                    FROM play_history GROUP BY tuneId
                ) h ON h.tuneId = tunes.id
                ORDER BY h.lastPlayed DESC
                LIMIT ?
            """, arguments: [limit])
        }
    }

    public func recentlyPlayedCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT tuneId) FROM play_history") ?? 0
        }
    }

    public func clearHistory() throws {
        try dbWriter.write { db in
            try PlayHistoryRow.deleteAll(db)
        }
    }

    // MARK: SQL sort helpers

    private static let textColumns: Set<String> =
        ["title", "author", "released", "path", "format", "clock", "model"]
    private static let validColumns: Set<String> =
        textColumns.union(["songs", "defaultLengthMs", "version", "sidChips"])

    private static func orderClause(
        from columns: [(column: String, ascending: Bool)]
    ) -> String {
        var parts: [String] = []
        for (col, asc) in columns {
            guard validColumns.contains(col) else { continue }
            let dir = asc ? "ASC" : "DESC"
            if textColumns.contains(col) {
                parts.append("tunes.\(col) IS NULL, tunes.\(col) COLLATE NOCASE \(dir)")
            } else {
                parts.append("tunes.\(col) IS NULL, tunes.\(col) \(dir)")
            }
        }
        if parts.isEmpty {
            return "tunes.author IS NULL, tunes.author COLLATE NOCASE ASC, tunes.title IS NULL, tunes.title COLLATE NOCASE ASC"
        }
        return parts.joined(separator: ", ")
    }
}

import Foundation
import SIDEngine

/// Walks an HVSC tree, parses each .sid header, computes its HVSC#68+ MD5
/// (over file content with the load-address-injection rule), and inserts rows
/// into a CatalogDB.
public actor HVSCIndexer {
    public struct Progress: Sendable {
        public let processed: Int
        public let inserted: Int
        public let total: Int?            // best-effort estimate; nil while still discovering
        public let currentPath: String?
    }

    public init() {}

    public func reindex(
        source: HVSCSource,
        into db: CatalogDB,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Int {
        try source.validate()

        let songlengths = try Songlengths(contentsOf: source.songlengthsURL)
        // Resolve symlinks once (e.g. /var → /private/var) so relative paths match.
        let rootPath = source.root.standardizedFileURL.resolvingSymlinksInPath().path

        // Stage 1: enumerate all .sid paths up front. ~55k files → fast.
        var paths: [URL] = []
        paths.reserveCapacity(60_000)
        for dir in source.availableTuneDirs() {
            paths.append(contentsOf: enumerateSIDs(under: dir))
        }
        let total = paths.count

        // Upsert by path instead of clear-and-reinsert so tune ids stay stable
        // and playlist / play-history references survive the re-index.
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(total)
        // Files that exist on disk but failed to parse/hash this pass. They
        // must be excluded from the post-index deletion: a transient read
        // failure must not delete a previously indexed tune (cascading it
        // out of playlists and play history).
        var failedPaths = Set<String>()

        // Accumulate upserts and commit them in batches — one transaction per
        // tune dominated re-index time at ~55k files.
        let batchSize = 500
        var batch: [(tune: TuneRow, lengths: [Int])] = []
        batch.reserveCapacity(batchSize)

        var processed = 0
        var inserted = 0

        func flush() throws {
            guard !batch.isEmpty else { return }
            _ = try db.upsert(tunes: batch)
            inserted += batch.count
            batch.removeAll(keepingCapacity: true)
        }

        for url in paths {
            processed += 1
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relPath: String
            if resolved.hasPrefix(rootPath + "/") {
                relPath = String(resolved.dropFirst(rootPath.count + 1))
            } else {
                relPath = resolved  // fall back to absolute; shouldn't normally happen
            }
            do {
                // Parse only the leading header bytes; the full file is read
                // once more below by the MD5 pass, which genuinely needs it.
                guard let headerData = Self.readHeader(url) else {
                    failedPaths.insert(relPath)
                    continue
                }
                let header = try PSIDHeader(data: headerData)
                guard let md5 = SIDPlayerEngine.md5(forFileAt: url.path) else {
                    failedPaths.insert(relPath)
                    continue
                }
                let lengths = songlengths.lengthsByMD5[md5] ?? []

                let row = TuneRow(
                    path:     relPath,
                    md5:      md5,
                    format:   header.format.rawValue,
                    version:  Int(header.version),
                    title:    header.title,
                    author:   header.author,
                    released: header.released,
                    songs:    Int(header.songs),
                    startSong: Int(header.startSong),
                    clock:    header.clock.displayName,
                    model:    header.model.displayName,
                    sidChips: header.sidChips,
                    defaultLengthMs: nil  // CatalogDB.upsert fills this
                )
                batch.append((tune: row, lengths: lengths))
                seenPaths.insert(relPath)
            } catch {
                // Skip unreadable / malformed tunes but keep going.
                failedPaths.insert(relPath)
            }

            // Commit a full batch. Kept outside the per-tune `do` so a DB write
            // failure propagates rather than being swallowed as a "bad tune".
            if batch.count >= batchSize { try flush() }

            if processed % 250 == 0, let progress {
                progress(.init(
                    processed: processed,
                    inserted: inserted,
                    total: total,
                    currentPath: url.lastPathComponent
                ))
                await Task.yield()
            }
        }
        try flush()

        // Drop rows for files that no longer exist, then heal any playlist
        // position gaps their removal may have cascaded. Files that merely
        // failed this pass are kept — only confirmed-absent paths get dropped.
        try db.deleteTunesExcept(paths: seenPaths.union(failedPaths))
        try db.normalizePlaylistPositions()

        progress?(.init(processed: processed, inserted: inserted, total: total, currentPath: nil))
        return inserted
    }

    /// Enumerate .sid files under a directory using FileManager (depth-unlimited).
    private func enumerateSIDs(under dir: URL) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return out }

        for case let url as URL in it {
            let lower = url.pathExtension.lowercased()
            if lower == "sid" {
                out.append(url)
            }
        }
        return out
    }

    /// Reads just the leading header bytes (enough for `PSIDHeader`) instead of
    /// pulling the whole tune into memory — across ~55k files that's a lot of
    /// avoided I/O, since only the first ~0x7E bytes are parsed.
    private static func readHeader(_ url: URL, maxBytes: Int = 128) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}


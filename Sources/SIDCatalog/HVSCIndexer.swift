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

        var processed = 0
        var inserted = 0
        for url in paths {
            processed += 1
            do {
                let header = try PSIDHeader(contentsOf: url)
                guard let md5 = SIDPlayerEngine.md5(forFileAt: url.path) else {
                    continue
                }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
                let relPath: String
                if resolved.hasPrefix(rootPath + "/") {
                    relPath = String(resolved.dropFirst(rootPath.count + 1))
                } else {
                    relPath = resolved  // fall back to absolute; shouldn't normally happen
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
                _ = try db.upsert(tune: row, lengths: lengths)
                seenPaths.insert(relPath)
                inserted += 1
            } catch {
                // Skip unreadable / malformed tunes but keep going.
            }

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

        // Drop rows for files that no longer exist, then heal any playlist
        // position gaps their removal may have cascaded.
        try db.deleteTunesExcept(paths: seenPaths)
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
}


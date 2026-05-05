import Foundation
import SIDEngine
import SIDCatalog

// Phase 3 CLI: exercise the catalog layer.
//
//   sidcat download                       # discovers + downloads + extracts HVSC
//   sidcat index <hvsc-root>              # walks the tree and (re)builds the DB
//   sidcat search <query>                 # FTS5 search across title/author/path
//   sidcat info <id>
//   sidcat play <id> [seconds]
//
// State lives at ~/Library/Application Support/sidplayer/.

let support = try {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("sidplayer", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let dbURL = support.appendingPathComponent("catalog.sqlite")
let hvscDir = support.appendingPathComponent("hvsc", isDirectory: true)

func openDB() throws -> CatalogDB {
    try CatalogDB(url: dbURL)
}

func openSource() throws -> HVSCSource {
    let candidate = HVSCSource(root: hvscDir)
    if FileManager.default.fileExists(atPath: candidate.songlengthsURL.path) {
        return candidate
    }
    let nested = try HVSCDownloader.locateHVSCRoot(under: hvscDir)
    return HVSCSource(root: nested)
}

func usageAndExit() -> Never {
    FileHandle.standardError.write(Data("""
        usage:
          sidcat download
          sidcat index [<hvsc-root>]
          sidcat search <query>
          sidcat info <id>
          sidcat play <id> [seconds]

        State: \(support.path)

        """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usageAndExit() }

switch cmd {

case "download":
    print("Discovering latest HVSC version…")
    let dl = HVSCDownloader()
    let result = try await dl.downloadAndExtract(to: hvscDir) { phase in
        switch phase.kind {
        case .discoveringManifest:
            break
        case .downloading(let got, let total):
            if let total {
                let pct = Double(got) / Double(total) * 100
                print(String(format: "  download: %@ / %@ (%.1f%%)\r",
                             fmtBytes(got), fmtBytes(total), pct), terminator: "")
            } else {
                print(String(format: "  download: %@\r", fmtBytes(got)), terminator: "")
            }
            fflush(stdout)
        case .extracting:
            print("\n  extracting via bsdtar…")
        case .done:
            break
        }
    }
    print("\nHVSC #\(result.version) at \(result.source.root.path)")

case "index":
    let source: HVSCSource
    if args.count >= 2 {
        source = HVSCSource(root: URL(fileURLWithPath: args[1]))
    } else {
        source = try openSource()
    }
    let db = try openDB()
    print("Indexing \(source.root.path) → \(dbURL.path)")
    let indexer = HVSCIndexer()
    let count = try await indexer.reindex(source: source, into: db) { p in
        if let total = p.total {
            let pct = Double(p.processed) / Double(total) * 100
            print(String(format: "  %d / %d  (%.1f%%)  %@\u{1B}[K\r",
                         p.processed, total, pct, p.currentPath ?? ""),
                  terminator: "")
            fflush(stdout)
        }
    }
    print("\nIndexed \(count) tunes.")

case "search":
    guard args.count >= 2 else { usageAndExit() }
    let q = args.dropFirst().joined(separator: " ")
    let db = try openDB()
    let rows = try db.search(q, limit: 50)
    print("\(rows.count) result(s):")
    for r in rows {
        let ms = r.defaultLengthMs ?? 0
        print(String(format: "  [%5d] %@ — %@ (%@)  %@",
                     r.id ?? -1,
                     r.title ?? "?",
                     r.author ?? "?",
                     r.released ?? "?",
                     fmtMs(ms)))
    }

case "info":
    guard args.count >= 2, let id = Int64(args[1]) else { usageAndExit() }
    let db = try openDB()
    guard let t = try db.tune(id: id) else {
        print("no tune with id=\(id)")
        exit(1)
    }
    let lens = try db.lengths(tuneId: id)
    print("Title:    \(t.title ?? "?")")
    print("Author:   \(t.author ?? "?")")
    print("Released: \(t.released ?? "?")")
    print("Path:     \(t.path)")
    print("Format:   \(t.format) v\(t.version)  songs: \(t.songs)  start: \(t.startSong)")
    print("Clock:    \(t.clock)  Model: \(t.model)  SIDs: \(t.sidChips)")
    print("MD5:      \(t.md5)")
    if !lens.isEmpty {
        print("Subtune lengths:")
        for l in lens {
            print(String(format: "  [%2d] %@", l.subtune + 1, fmtMs(l.durationMs)))
        }
    }

case "play":
    guard args.count >= 2, let id = Int64(args[1]) else { usageAndExit() }
    let secs = args.count >= 3 ? (Double(args[2]) ?? 30) : 30
    let db = try openDB()
    guard let t = try db.tune(id: id) else {
        print("no tune with id=\(id)")
        exit(1)
    }
    let source = try openSource()
    let absPath = source.root.appendingPathComponent(t.path).path
    let player = SIDPlayer()
    try player.load(path: absPath)
    print("Playing: \(t.title ?? "?") — \(t.author ?? "?")  [\(t.path)]")
    try player.play()
    try await Task.sleep(for: .seconds(secs))
    player.stop()

default:
    usageAndExit()
}

// MARK: - formatters

@Sendable func fmtBytes(_ n: Int64) -> String {
    let mb = Double(n) / 1_048_576
    if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
    return String(format: "%.1f MB", mb)
}

@Sendable func fmtMs(_ ms: Int) -> String {
    let total = ms / 1000
    return String(format: "%d:%02d", total / 60, total % 60)
}

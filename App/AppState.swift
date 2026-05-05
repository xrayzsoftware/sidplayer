import Foundation
import Observation
import SIDEngine
import SIDCatalog

/// Single source of truth for the UI. Owns the player, the catalog, and
/// the search/queue state. Updates flow MainActor-only.
@MainActor
@Observable
public final class AppState {

    // MARK: First-run
    public enum BootstrapStatus: Equatable {
        case notReady
        case ready
        case downloadingHVSC(progress: Double, label: String)
        case indexing(processed: Int, total: Int?)
        case error(String)
    }
    public var bootstrap: BootstrapStatus = .notReady

    // MARK: Catalog
    public var catalog: CatalogDB?
    public var hvscSource: HVSCSource?
    public var rows: [TuneItem] = []
    public var selectedID: Int64?

    // MARK: Search
    public var searchQuery: String = ""

    // MARK: Player
    public let player = SIDPlayer()
    public var isPlaying: Bool = false
    public var currentTuneID: Int64?
    public var currentTime: TimeInterval = 0
    public var currentSubtune: Int = 1
    public var subtuneCount: Int = 1
    public var defaultLengthMs: Int = 0
    public var volume: Double = 0.8

    // MARK: Queue
    public var queue: [Int64] = []           // tune IDs in play order
    public var queueIndex: Int = 0

    // Periodic time updater while playing.
    private var ticker: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    public func bootstrap() async {
        let support = supportDir()
        let dbURL  = support.appendingPathComponent("catalog.sqlite")
        let hvsc   = support.appendingPathComponent("hvsc", isDirectory: true)

        do {
            let db = try CatalogDB(url: dbURL)
            self.catalog = db

            // Try to find an HVSC source under the canonical location.
            if FileManager.default.fileExists(atPath: hvsc.appendingPathComponent("DOCUMENTS/Songlengths.md5").path) {
                self.hvscSource = HVSCSource(root: hvsc)
            } else if let nested = try? HVSCDownloader.locateHVSCRoot(under: hvsc) {
                self.hvscSource = HVSCSource(root: nested)
            }

            try await refreshSearch()
            self.bootstrap = ((try? db.count()) ?? 0) > 0 ? .ready : .notReady
        } catch {
            self.bootstrap = .error(error.localizedDescription)
        }
    }

    private func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("sidplayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: HVSC download + index

    public func downloadHVSC() async {
        let dest = supportDir().appendingPathComponent("hvsc", isDirectory: true)
        bootstrap = .downloadingHVSC(progress: 0, label: "discovering manifest…")
        do {
            let dl = HVSCDownloader()
            let result = try await dl.downloadAndExtract(to: dest) { phase in
                Task { @MainActor in
                    switch phase.kind {
                    case .discoveringManifest:
                        self.bootstrap = .downloadingHVSC(progress: 0, label: "discovering manifest…")
                    case .downloading(let got, let total):
                        if let total, total > 0 {
                            let pct = Double(got) / Double(total)
                            self.bootstrap = .downloadingHVSC(
                                progress: pct,
                                label: String(format: "%.0f / %.0f MB",
                                              Double(got) / 1_048_576,
                                              Double(total) / 1_048_576)
                            )
                        } else {
                            self.bootstrap = .downloadingHVSC(
                                progress: 0,
                                label: String(format: "%.0f MB", Double(got) / 1_048_576)
                            )
                        }
                    case .extracting:
                        self.bootstrap = .downloadingHVSC(progress: 1, label: "extracting…")
                    case .done:
                        self.bootstrap = .indexing(processed: 0, total: nil)
                    }
                }
            }
            self.hvscSource = result.source
            try await reindex()
        } catch {
            bootstrap = .error("HVSC download failed: \(error.localizedDescription)")
        }
    }

    public func reindex() async throws {
        guard let source = hvscSource, let db = catalog else { return }
        bootstrap = .indexing(processed: 0, total: nil)
        let indexer = HVSCIndexer()
        _ = try await indexer.reindex(source: source, into: db) { p in
            Task { @MainActor in
                self.bootstrap = .indexing(processed: p.processed, total: p.total)
            }
        }
        bootstrap = .ready
        try await refreshSearch()
    }

    public func setHVSCFolder(_ url: URL) async {
        let candidate = HVSCSource(root: url)
        do {
            try candidate.validate()
            hvscSource = candidate
            try await reindex()
        } catch {
            bootstrap = .error(error.localizedDescription)
        }
    }

    // MARK: Search

    public func refreshSearch() async throws {
        guard let db = catalog else { return }
        let q = searchQuery
        let results = try db.search(q, limit: 1000)
        self.rows = results.compactMap(TuneItem.init(row:))
    }

    // MARK: Playback

    public func play(tuneID: Int64) async {
        guard let source = hvscSource, let db = catalog else { return }
        do {
            guard let row = try db.tune(id: tuneID) else { return }
            let abs = source.root.appendingPathComponent(row.path).path
            try player.load(path: abs)
            try player.play()
            currentTuneID    = tuneID
            currentSubtune   = player.currentSong
            subtuneCount     = player.info?.songCount ?? 1
            defaultLengthMs  = row.defaultLengthMs ?? 0
            isPlaying        = true
            startTicker()
        } catch {
            bootstrap = .error(error.localizedDescription)
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? player.play()
            isPlaying = true
        }
    }

    public func nextSubtune() {
        try? player.nextSong()
        currentSubtune = player.currentSong
    }

    public func previousSubtune() {
        try? player.previousSong()
        currentSubtune = player.currentSong
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 10 Hz
                await MainActor.run {
                    guard let self else { return }
                    self.currentTime = self.player.currentTime
                }
            }
        }
    }
}

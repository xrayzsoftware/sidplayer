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
    public var showSettingsSheet: Bool = false
    public var lastError: String?

    // MARK: Browse mode
    public enum BrowseMode: Equatable {
        case all
        case favorites
        case browse
    }
    public var browseMode: BrowseMode = .all
    public var browsePath: String = ""           // relative to HVSC root
    public var browseDirs: [String] = []         // child dirs at browsePath
    public var favoriteIDs: Set<Int64> = []

    // MARK: Theme
    public var theme: AppTheme = .systemDefault
    public var showScroller: Bool = true

    // MARK: Catalog
    public var catalog: CatalogDB?
    public var hvscSource: HVSCSource?
    /// Lazily loaded the first time the STIL popover opens.
    public var stil: STIL?
    public var rows: [TuneItem] = []
    /// Pre-sorted snapshot of `rows` for the Table view. Recomputed only
    /// when `rows` or `sortOrder` changes — sorting 60k items each body
    /// re-render was the bottleneck.
    public var sortedRows: [TuneItem] = []
    public var selectedID: Int64?
    public var sortOrder: [KeyPathComparator<TuneItem>] = [
        KeyPathComparator(\TuneItem.row.author, order: .forward),
        KeyPathComparator(\TuneItem.row.title,  order: .forward),
    ]

    private var sortGen: UInt64 = 0

    /// Sort is offloaded to a background task so clicking a column header
    /// doesn't block the UI. We tag each request with a generation; if a
    /// newer one starts, older results are discarded.
    public func applySort() {
        sortGen &+= 1
        let myGen = sortGen
        let snapshot = rows
        let order = sortOrder
        Task.detached(priority: .userInitiated) {
            let sorted = snapshot.sorted(using: order)
            await MainActor.run {
                guard self.sortGen == myGen else { return }
                self.sortedRows = sorted
            }
        }
    }

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
    /// Per-subtune lengths in ms (0-indexed by subtune). Empty if unknown.
    public var subtuneLengthsMs: [Int] = []
    /// Per-voice mute state for V1, V2, V3.
    public var voiceMuted: [Bool] = [false, false, false]
    public var volume: Double = 0.8 {
        didSet { player.setVolume(Float(volume)) }
    }

    private var ticker: Task<Void, Never>?

    private static let favoritesKey = "favoriteIDs.v1"
    private static let themeKey     = "themeID.v1"
    private static let scrollerKey  = "showScroller.v1"

    public init() {
        player.setVolume(Float(volume))
        loadFavorites()
        loadTheme()
        if UserDefaults.standard.object(forKey: Self.scrollerKey) != nil {
            showScroller = UserDefaults.standard.bool(forKey: Self.scrollerKey)
        }
    }

    public func toggleScroller() {
        showScroller.toggle()
        UserDefaults.standard.set(showScroller, forKey: Self.scrollerKey)
    }

    private func loadTheme() {
        if let id = UserDefaults.standard.string(forKey: Self.themeKey) {
            theme = AppTheme.preset(id: id)
        }
    }

    public func setTheme(_ t: AppTheme) {
        theme = t
        UserDefaults.standard.set(t.id, forKey: Self.themeKey)
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else { return }
        favoriteIDs = Set(ids)
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(Array(favoriteIDs)) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
    }

    public func toggleFavorite(_ id: Int64) {
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        saveFavorites()
        if browseMode == .favorites {
            Task { try? await refreshSearch() }
        }
    }

    public func setBrowseMode(_ mode: BrowseMode) {
        browseMode = mode
        searchQuery = ""    // clear filter on tab switch
        if mode == .browse && browsePath.isEmpty { browsePath = "" }
        Task { try? await refreshSearch() }
    }

    public func enterBrowseDir(_ name: String) {
        browsePath = browsePath.isEmpty ? name : "\(browsePath)/\(name)"
        Task { try? await refreshSearch() }
    }

    public func browseUp() {
        guard !browsePath.isEmpty else { return }
        if let slash = browsePath.lastIndex(of: "/") {
            browsePath = String(browsePath[..<slash])
        } else {
            browsePath = ""
        }
        Task { try? await refreshSearch() }
    }

    public func setBrowsePath(_ path: String) {
        browsePath = path
        Task { try? await refreshSearch() }
    }

    // MARK: Lifecycle

    public func bootstrap() async {
        let support = supportDir()
        let dbURL  = support.appendingPathComponent("catalog.sqlite")
        let hvsc   = support.appendingPathComponent("hvsc", isDirectory: true)

        do {
            let db = try CatalogDB(url: dbURL)
            self.catalog = db

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
        switch browseMode {
        case .all:
            // 60k items overload SwiftUI Table sorting (Debug builds in
            // particular). Cap at 1000 — use Search or Browse to find the
            // rest. Ranked results come back first regardless of query.
            let results = try db.search(searchQuery, limit: 1000)
            self.rows = results.compactMap(TuneItem.init(row:))
            self.browseDirs = []
            applySort()

        case .favorites:
            let ids = Array(favoriteIDs).sorted()
            var results = try db.tunes(ids: ids)
            // Apply local filter using current searchQuery if set.
            let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                results = results.filter {
                    ($0.title?.lowercased().contains(q) ?? false) ||
                    ($0.author?.lowercased().contains(q) ?? false)
                }
            }
            results.sort {
                ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending
            }
            self.rows = results.compactMap(TuneItem.init(row:))
            self.browseDirs = []
            applySort()

        case .browse:
            let (dirs, tunes) = try db.browse(prefix: browsePath)
            self.browseDirs = dirs
            self.rows = tunes.compactMap(TuneItem.init(row:))
            applySort()
        }
    }

    // MARK: Playback

    public func play(tuneID: Int64) async {
        guard let db = catalog else {
            lastError = "Catalog not open"
            return
        }
        guard let source = hvscSource else {
            lastError = "HVSC folder not configured. Open Settings to download or choose a folder."
            return
        }
        do {
            guard let row = try db.tune(id: tuneID) else {
                lastError = "Tune \(tuneID) not in catalog"
                return
            }
            let abs = source.root.appendingPathComponent(row.path).path
            guard FileManager.default.fileExists(atPath: abs) else {
                lastError = "File not found at \(abs)"
                return
            }
            try player.load(path: abs)
            try player.play()
            currentTuneID    = tuneID
            currentSubtune   = player.currentSong
            subtuneCount     = player.info?.songCount ?? 1
            defaultLengthMs  = row.defaultLengthMs ?? 0
            subtuneLengthsMs = ((try? db.lengths(tuneId: tuneID)) ?? []).map(\.durationMs)
            // Engines start with all voices unmuted by default; no explicit
            // call needed (and it would race with the producer thread's
            // play() loop). Just reset our UI state.
            voiceMuted       = [false, false, false]
            isPlaying        = true
            lastError        = nil
            startTicker()
        } catch {
            lastError = error.localizedDescription
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

    public func stop() {
        player.stop()
        isPlaying = false
        currentTime = 0
        ticker?.cancel()
        ticker = nil
    }

    public func skipForward() {
        if subtuneCount > 1 {
            try? player.nextSong()
            currentSubtune = player.currentSong
        } else {
            jumpToAdjacentTrack(offset: +1)
        }
    }

    public func skipBackward() {
        if subtuneCount > 1 {
            try? player.previousSong()
            currentSubtune = player.currentSong
        } else {
            jumpToAdjacentTrack(offset: -1)
        }
    }

    private func jumpToAdjacentTrack(offset: Int) {
        guard let id = currentTuneID,
              let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        let next = (idx + offset + rows.count) % rows.count
        let target = rows[next].id
        selectedID = target
        Task { await play(tuneID: target) }
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
                    self.checkAutoAdvance()
                }
            }
        }
    }

    /// Auto-advance when the current subtune reaches its songlength entry.
    /// Subtune ends → next subtune. Last subtune ends → next track.
    private func checkAutoAdvance() {
        guard isPlaying else { return }
        let subIdx = max(0, currentSubtune - 1)
        guard subIdx < subtuneLengthsMs.count else { return }
        let lenMs = subtuneLengthsMs[subIdx]
        guard lenMs > 0 else { return }
        guard currentTime * 1000 >= Double(lenMs) else { return }

        if currentSubtune < subtuneCount {
            try? player.nextSong()
            currentSubtune = player.currentSong
            currentTime = 0
        } else {
            jumpToAdjacentTrack(offset: +1)
        }
    }

    public func toggleVoiceMute(_ voice: Int) {
        guard (0..<3).contains(voice) else { return }
        voiceMuted[voice].toggle()
        player.engine.setVoiceMuted(voice, muted: voiceMuted[voice])
    }

    /// STIL is large (~60 MB text). Loaded once on first request, off main.
    public func ensureSTILLoaded() async {
        guard stil == nil, let source = hvscSource else { return }
        let url = source.stilURL
        let loaded = await Task.detached(priority: .userInitiated) {
            try? STIL(contentsOf: url)
        }.value
        if let loaded { self.stil = loaded }
    }
}

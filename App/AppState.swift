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
        case playlists                  // root: list of user playlists
        case playlist(Int64)            // viewing a single playlist by id
        case recentlyPlayed             // play history

        /// Tab-bar grouping. `.playlists` and `.playlist(_)` share a tab.
        public var category: String {
            switch self {
            case .all:              return "all"
            case .favorites:        return "favorites"
            case .browse:           return "browse"
            case .playlists, .playlist: return "playlists"
            case .recentlyPlayed:   return "recent"
            }
        }
    }
    public var browseMode: BrowseMode = .all
    public var browsePath: String = ""           // relative to HVSC root
    public var browseDirs: [String] = []         // child dirs at browsePath
    public var favoriteIDs: Set<Int64> = []

    // MARK: Playlists
    public var recentCount: Int = 0
    public var playlists: [Playlist] = []
    public var playlistCounts: [Int64: Int] = [:]

    // MARK: Theme
    public var theme: AppTheme = .systemDefault
    public var showScroller: Bool = true
    public var showVisualizers: Bool = true

    // MARK: Visualizer mode
    public enum SecondaryVizMode: String, CaseIterable, Sendable {
        case peakMeter, spectrogram, vectorscope

        public var label: String {
            switch self {
            case .peakMeter:   return "PEAKS"
            case .spectrogram: return "WATERFALL"
            case .vectorscope: return "PHOSPHOR"
            }
        }
    }
    public var secondaryViz: SecondaryVizMode = .peakMeter

    // MARK: Shuffle & Repeat
    public enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one

        public var icon: String {
            switch self {
            case .off, .all: return "repeat"
            case .one:       return "repeat.1"
            }
        }
    }
    public var shuffleEnabled: Bool = false
    public var repeatMode: RepeatMode = .off
    private var shufflePlayed: Set<Int64> = []
    /// Chronological order of tunes played in the current shuffle session, so
    /// Previous/Next can walk the real order instead of always re-randomising.
    private var shuffleHistory: [Int64] = []

    /// Snapshot of the list playback is walking, captured when the user starts
    /// a track. Skip / auto-advance / shuffle operate on this — not the live
    /// view — so switching tab/filter mid-playback doesn't silently change (or
    /// dead-end) what plays next.
    public private(set) var playQueue: [Int64] = []
    /// True only while skip/auto-advance is assigning `selectedID`, so its
    /// didSet doesn't re-snapshot the queue from the (possibly different) view.
    private var navigatingWithinQueue = false

    // MARK: Emulation config
    public var emulationConfig: EmulationConfig = EmulationConfig()

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
    public var selectedID: Int64? {
        // Selecting a row is the single trigger for playback. Views only *set*
        // this (table selection, taps); skip/auto-advance set it too. This
        // replaces the old pattern where both an explicit play() call and a
        // view's .onChange fired, double-loading every track.
        didSet {
            guard let id = selectedID, id != oldValue else { return }
            if !navigatingWithinQueue {
                // A user pick from the current view: that view becomes the play
                // queue, and a fresh shuffle session starts over it.
                playQueue = sortedRows.map(\.id)
                shufflePlayed.removeAll()
                shuffleHistory.removeAll()
            }
            Task { await play(tuneID: id) }
        }
    }
    public var sortOrder: [KeyPathComparator<TuneItem>] = [
        KeyPathComparator(\TuneItem.row.author, order: .forward),
        KeyPathComparator(\TuneItem.row.title,  order: .forward),
    ]

    private var sortGen: UInt64 = 0
    private var searchGen: UInt64 = 0

    /// For .all mode, re-queries SQL with the current sort order — the
    /// database handles ORDER BY instantly even at 65k rows. For smaller
    /// data sets (favorites, browse, playlists) sorts in-memory on a
    /// background task with generation tagging.
    public func applySort() {
        if browseMode == .all {
            Task { try? await refreshSearch() }
            return
        }
        sortGen &+= 1
        let myGen = sortGen
        let snapshot = rows
        let order = sortOrder
        Task.detached(priority: .userInitiated) { [weak self] in
            let sorted = snapshot.sorted(using: order)
            await MainActor.run {
                guard let self, self.sortGen == myGen else { return }
                self.sortedRows = sorted
            }
        }
    }

    /// Builds a SearchFilters from the current filter UI state.
    private func currentSearchFilters() -> CatalogDB.SearchFilters {
        var f = CatalogDB.SearchFilters()
        if filterModel != .any { f.model = filterModel.rawValue }
        if filterClock != .any { f.clock = filterClock.rawValue }
        if let y = Int(filterYearFrom), y > 0 { f.yearFrom = y }
        if let y = Int(filterYearTo), y > 0 { f.yearTo = y }
        return f
    }

    /// Converts the current SwiftUI sort descriptors into SQL column names.
    private func sqlSortColumns() -> [(column: String, ascending: Bool)] {
        sortOrder.compactMap { kpc in
            let col: String
            if kpc.keyPath == \TuneItem.row.author          { col = "author" }
            else if kpc.keyPath == \TuneItem.row.title      { col = "title" }
            else if kpc.keyPath == \TuneItem.row.released   { col = "released" }
            else if kpc.keyPath == \TuneItem.row.songs      { col = "songs" }
            else if kpc.keyPath == \TuneItem.row.defaultLengthMs { col = "defaultLengthMs" }
            else { return nil }
            return (col, kpc.order == .forward)
        }
    }

    // MARK: Search
    public var searchQuery: String = ""

    // MARK: Search Filters (transient, not persisted)
    public enum ModelFilter: String, CaseIterable, Sendable {
        case any = "Any", mos6581 = "6581", mos8580 = "8580"
    }
    public enum ClockFilter: String, CaseIterable, Sendable {
        case any = "Any", pal = "PAL", ntsc = "NTSC"
    }
    public var filterModel: ModelFilter = .any
    public var filterClock: ClockFilter = .any
    public var filterYearFrom: String = ""
    public var filterYearTo: String = ""

    public var hasActiveFilters: Bool {
        filterModel != .any || filterClock != .any
        || !filterYearFrom.isEmpty || !filterYearTo.isEmpty
    }

    public func clearFilters() {
        filterModel = .any
        filterClock = .any
        filterYearFrom = ""
        filterYearTo = ""
        Task { try? await refreshSearch() }
    }

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
    public var volume: Double = 0.8 {
        didSet { player.setVolume(Float(volume)) }
    }

    private var ticker: Task<Void, Never>?

    private static let favoritesKey = "favoriteIDs.v1"
    private static let themeKey     = "themeID.v1"
    private static let scrollerKey  = "showScroller.v1"
    private static let vizKey       = "showVisualizers.v1"
    private static let secondaryVizKey = "secondaryViz.v1"
    private static let shuffleKey      = "shuffle.v1"
    private static let repeatKey       = "repeatMode.v1"
    private static let sidModelKey    = "sidModel.v1"
    private static let clockKey       = "clock.v1"
    private static let digiBoostKey   = "digiBoost.v1"
    private static let samplingKey    = "sampling.v1"

    public init() {
        player.setVolume(Float(volume))
        loadFavorites()
        loadTheme()
        if UserDefaults.standard.object(forKey: Self.scrollerKey) != nil {
            showScroller = UserDefaults.standard.bool(forKey: Self.scrollerKey)
        }
        if UserDefaults.standard.object(forKey: Self.vizKey) != nil {
            showVisualizers = UserDefaults.standard.bool(forKey: Self.vizKey)
        }
        player.vizEnabled = showVisualizers
        if let raw = UserDefaults.standard.string(forKey: Self.secondaryVizKey),
           let mode = SecondaryVizMode(rawValue: raw) {
            secondaryViz = mode
        }
        if UserDefaults.standard.object(forKey: Self.shuffleKey) != nil {
            shuffleEnabled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.repeatKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        loadEmulationConfig()
    }

    public func cycleSecondaryViz() {
        let all = SecondaryVizMode.allCases
        let i = all.firstIndex(of: secondaryViz) ?? 0
        secondaryViz = all[(i + 1) % all.count]
        UserDefaults.standard.set(secondaryViz.rawValue, forKey: Self.secondaryVizKey)
    }

    public func toggleShuffle() {
        shuffleEnabled.toggle()
        UserDefaults.standard.set(shuffleEnabled, forKey: Self.shuffleKey)
        shufflePlayed.removeAll()
        shuffleHistory.removeAll()
    }

    public func cycleRepeat() {
        let all = RepeatMode.allCases
        let i = all.firstIndex(of: repeatMode) ?? 0
        repeatMode = all[(i + 1) % all.count]
        UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatKey)
    }

    private func loadEmulationConfig() {
        if let raw = UserDefaults.standard.string(forKey: Self.sidModelKey),
           let val = EmulationConfig.SIDModelChoice(rawValue: raw) {
            emulationConfig.sidModel = val
        }
        if let raw = UserDefaults.standard.string(forKey: Self.clockKey),
           let val = EmulationConfig.ClockChoice(rawValue: raw) {
            emulationConfig.clock = val
        }
        if UserDefaults.standard.object(forKey: Self.digiBoostKey) != nil {
            emulationConfig.digiBoost = UserDefaults.standard.bool(forKey: Self.digiBoostKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.samplingKey),
           let val = EmulationConfig.SamplingMethod(rawValue: raw) {
            emulationConfig.sampling = val
        }
        player.emulationConfig = emulationConfig
    }

    public func updateEmulationConfig(_ config: EmulationConfig) {
        emulationConfig = config
        UserDefaults.standard.set(config.sidModel.rawValue, forKey: Self.sidModelKey)
        UserDefaults.standard.set(config.clock.rawValue, forKey: Self.clockKey)
        UserDefaults.standard.set(config.digiBoost, forKey: Self.digiBoostKey)
        UserDefaults.standard.set(config.sampling.rawValue, forKey: Self.samplingKey)
        player.emulationConfig = config
        if currentTuneID != nil {
            do {
                try player.reloadCurrentTune()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func toggleScroller() {
        showScroller.toggle()
        UserDefaults.standard.set(showScroller, forKey: Self.scrollerKey)
    }

    public func toggleVisualizers() {
        showVisualizers.toggle()
        UserDefaults.standard.set(showVisualizers, forKey: Self.vizKey)
        player.vizEnabled = showVisualizers
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
        searchQuery = ""
        if mode == .browse && browsePath.isEmpty { browsePath = "" }
        Task { try? await refreshSearch() }
    }

    // MARK: Playlists

    public func loadPlaylists() {
        guard let db = catalog else { return }
        playlists = (try? db.playlists()) ?? []
        var counts: [Int64: Int] = [:]
        for p in playlists {
            if let id = p.id {
                counts[id] = (try? db.playlistTrackCount(id: id)) ?? 0
            }
        }
        playlistCounts = counts
    }

    @discardableResult
    public func createPlaylist(name: String) -> Int64? {
        guard let db = catalog else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            let p = try db.createPlaylist(name: trimmed)
            loadPlaylists()
            return p.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func deletePlaylist(_ id: Int64) {
        try? catalog?.deletePlaylist(id: id)
        if case .playlist(let cur) = browseMode, cur == id {
            setBrowseMode(.playlists)
        }
        loadPlaylists()
    }

    public func renamePlaylist(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? catalog?.renamePlaylist(id: id, name: trimmed)
        loadPlaylists()
    }

    public func addToPlaylist(playlistID: Int64, tuneID: Int64) {
        try? catalog?.addToPlaylist(playlistId: playlistID, tuneId: tuneID)
        loadPlaylists()
        if case .playlist(let cur) = browseMode, cur == playlistID {
            Task { try? await refreshSearch() }
        }
    }

    /// Remove a tune from the currently-viewed playlist by its row index.
    public func removeFromCurrentPlaylist(at index: Int) {
        guard case .playlist(let pid) = browseMode else { return }
        try? catalog?.removeFromPlaylist(playlistId: pid, position: index)
        loadPlaylists()
        Task { try? await refreshSearch() }
    }

    public func enterPlaylist(_ id: Int64) {
        setBrowseMode(.playlist(id))
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

            // Prefer a previously-bookmarked user-chosen folder; fall back to
            // the default app-support `hvsc/` location populated by the
            // built-in downloader.
            if let bookmarked = HVSCBookmark.resolve() {
                let candidate = HVSCSource(root: bookmarked)
                if (try? candidate.validate()) != nil {
                    self.hvscSource = candidate
                } else {
                    HVSCBookmark.release(bookmarked)
                }
            }
            if hvscSource == nil {
                if FileManager.default.fileExists(atPath: hvsc.appendingPathComponent("DOCUMENTS/Songlengths.md5").path) {
                    self.hvscSource = HVSCSource(root: hvsc)
                } else if let nested = try? HVSCDownloader.locateHVSCRoot(under: hvsc) {
                    self.hvscSource = HVSCSource(root: nested)
                }
            }

            loadPlaylists()
            recentCount = (try? db.recentlyPlayedCount()) ?? 0
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
            HVSCBookmark.save(url)
            hvscSource = candidate
            try await reindex()
        } catch {
            bootstrap = .error(error.localizedDescription)
        }
    }

    // MARK: Search

    public func refreshSearch() async throws {
        guard let db = catalog else { return }
        // Bump every call so an in-flight (off-main) .all query knows it's been
        // superseded — e.g. the user switched tab/filter while it ran.
        searchGen &+= 1
        let gen = searchGen
        switch browseMode {
        case .all:
            // Run the SQL and the (up to 65k-row) TuneItem mapping off the main
            // actor so a large All-tab fetch can't jank the UI. Drop the result
            // if a newer refresh superseded us mid-flight.
            let query = searchQuery
            let sortCols = sqlSortColumns()
            let filters = currentSearchFilters()
            let items = try await Task.detached(priority: .userInitiated) {
                try db.search(query, sortedBy: sortCols, filters: filters)
                    .compactMap(TuneItem.init(row:))
            }.value
            guard searchGen == gen else { return }
            self.rows = items
            self.sortedRows = items
            self.browseDirs = []

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

        case .recentlyPlayed:
            let results = try db.recentlyPlayed(limit: 200)
            self.rows = results.compactMap(TuneItem.init(row:))
            self.sortedRows = self.rows
            self.browseDirs = []

        case .playlists:
            self.rows = []
            self.sortedRows = []
            self.browseDirs = []
            loadPlaylists()

        case .playlist(let id):
            let tunes = (try? db.playlistTracks(id: id)) ?? []
            self.rows = tunes.compactMap(TuneItem.init(row:))
            // Preserve playlist order; user-clicked column header sorts apply
            // afterwards via the Table's sortBinding.
            self.sortedRows = self.rows
            self.browseDirs = []
        }
        // Note: the shuffle session is tied to `playQueue` (snapshotted when
        // the user starts a track), not the visible list, so it deliberately
        // survives tab/filter changes.
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
            isPlaying        = true
            lastError        = nil
            startTicker()
            try? db.recordPlay(tuneId: tuneID, subtune: player.currentSong)
            recentCount = (try? db.recentlyPlayedCount()) ?? recentCount
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

    /// Skip to an adjacent track. Repeat-one is deliberately *not* handled here
    /// — a manual Next/Prev should move off the current track even with
    /// repeat-one set; auto-advance handles the replay itself (see
    /// `checkAutoAdvance`).
    private func jumpToAdjacentTrack(offset: Int) {
        let list = playQueue
        guard let id = currentTuneID, !list.isEmpty else { return }

        let target: Int64

        if shuffleEnabled {
            // Record the current track in the shuffle session before moving, so
            // Previous can step back through the order actually played.
            if !shuffleHistory.contains(id) { shuffleHistory.append(id) }
            shufflePlayed.insert(id)

            if offset < 0 {
                // Previous: walk back through real play order; stop at the start.
                guard let cur = shuffleHistory.firstIndex(of: id), cur > 0 else { return }
                target = shuffleHistory[cur - 1]
            } else if let cur = shuffleHistory.firstIndex(of: id),
                      cur < shuffleHistory.count - 1 {
                // Next after a Previous: replay the already-chosen forward order.
                target = shuffleHistory[cur + 1]
            } else {
                // Next at the head: pick a fresh random unplayed track.
                let candidates = list.filter { !shufflePlayed.contains($0) }
                if candidates.isEmpty {
                    if repeatMode == .off { stop(); return }
                    // Repeat-all: start a fresh pass, avoid replaying current.
                    shufflePlayed = [id]
                    shuffleHistory = [id]
                    let fresh = list.filter { $0 != id }
                    guard let pick = fresh.randomElement() else { stop(); return }
                    target = pick
                } else {
                    target = candidates.randomElement()!
                }
                shuffleHistory.append(target)
            }
        } else {
            guard let idx = list.firstIndex(of: id) else { return }
            let next = idx + offset
            if repeatMode == .off && (next < 0 || next >= list.count) {
                stop()
                return
            }
            target = list[((next % list.count) + list.count) % list.count]
        }

        // Drives playback via selectedID's didSet, but flagged so the didSet
        // doesn't re-snapshot the queue (we're moving within it). When target
        // already equals the current selection (a 1-track repeat-all wrap), the
        // didSet won't fire, so replay explicitly.
        if target == selectedID {
            Task { await play(tuneID: target) }
        } else {
            navigatingWithinQueue = true
            selectedID = target
            navigatingWithinQueue = false
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
        } else if repeatMode == .one, let id = currentTuneID {
            Task { await play(tuneID: id) }
        } else {
            jumpToAdjacentTrack(offset: +1)
        }
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

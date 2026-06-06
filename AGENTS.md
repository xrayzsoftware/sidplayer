# AGENTS.md — SID Player

Agent instructions for the SID Player macOS app. Read this before making any changes.

---

## Commands

```bash
# Regenerate the Xcode project from project.yml (required after any project.yml edit)
xcodegen generate

# Build all Swift package targets (fast; use this for non-UI changes)
swift build

# Run all tests
swift test

# Run a specific test suite
swift test --filter SIDEngineTests
swift test --filter SIDCatalogTests

# Build the .app and install it to /Applications (triggers xcodegen internally)
./scripts/install.sh

# Build Release via xcodebuild (no install)
xcodebuild -project SIDPlayer.xcodeproj -scheme SIDPlayer -configuration Release -destination 'platform=macOS' build

# Build a distributable DMG (requires signing identity)
./scripts/dmg.sh

# Notarize a built DMG
./scripts/notarize.sh
```

**After any code change**: run `swift build` and `swift test` to verify. For
App-layer changes (`App/`) that can't be exercised by `swift test`, do a
`./scripts/install.sh` and smoke-test manually.

---

## Project structure

```
sidplayer/
├── Sources/
│   ├── CSIDEngine/          # C++/ObjC++ bridge to libsidplayfp
│   │   ├── include/         # Public headers for Swift overlay
│   │   └── Vendor/
│   │       ├── include/     # libsidplayfp C++ headers (vendored, do not edit)
│   │       └── lib/
│   │           └── libsidplayfp.a   # Static archive (arm64, do not modify)
│   ├── SIDEngine/           # Swift playback layer
│   │   ├── SIDPlayer.swift  # High-level playback controller (AVAudioEngine + producer thread)
│   │   ├── SIDExporter.swift # Export current tune to WAV
│   │   ├── PSIDHeader.swift # Pure-Swift .sid file header parser
│   │   ├── Songlengths.swift # HVSC SONGLENGTHS.md5 parser
│   │   ├── RingBuffer.swift # Lock-free ring buffer between producer and audio render thread
│   │   └── VizTap.swift     # PCM tap fed to visualizers
│   ├── SIDCatalog/          # HVSC catalog layer (SQLite via GRDB)
│   │   ├── CatalogDB.swift  # Database schema, search, playlists, play history
│   │   ├── HVSCDownloader.swift # Downloads & extracts HVSC .7z archive
│   │   ├── HVSCIndexer.swift    # Walks HVSC tree, parses headers, upserts into DB
│   │   ├── HVSCSource.swift     # Represents a local HVSC installation
│   │   └── STIL.swift           # STIL (SID Tune Information List) parser
│   ├── sidspike/            # CLI spike harness for SIDEngine (debugging only)
│   └── sidcat/              # CLI tool: catalog search and playback
├── App/                     # SwiftUI macOS application
│   ├── AppState.swift       # @Observable single source of truth; owns player + catalog
│   ├── SIDPlayerApp.swift   # App entry point; sets up AppState, window group
│   ├── ContentView.swift    # Root view; delegates to TabBarView
│   ├── TuneItem.swift       # View model wrapping TuneRow for SwiftUI Table
│   ├── Theme.swift          # AppTheme enum + color definitions
│   ├── HVSCBookmark.swift   # Security-scoped bookmark persistence (sandbox)
│   └── Views/
│       ├── BrowseView.swift         # Directory tree browser
│       ├── FilterBar.swift          # Model/clock/year filter controls
│       ├── FirstRunView.swift       # HVSC download / onboarding flow
│       ├── MiniPlayerView.swift     # Floating mini player window
│       ├── NowPlayingHeader.swift   # Current tune info + STIL popover trigger
│       ├── PlaylistDetailView.swift # Single playlist contents
│       ├── PlaylistsRootView.swift  # Playlist list + management
│       ├── QueueBar.swift           # Play queue sidebar
│       ├── STILScrollerView.swift   # Scrolling STIL text display
│       ├── SettingsSheet.swift      # Emulation settings + theme
│       ├── TabBarView.swift         # Bottom tab bar (All / Favourites / Browse / Playlists)
│       ├── TrackListView.swift      # Main sortable SwiftUI Table of tunes
│       ├── TransportBar.swift       # Play/pause/skip/volume/shuffle/repeat controls
│       └── Visualizers/
│           ├── FFTAnalyzer.swift    # Hann-windowed vDSP FFT helper
│           ├── PeakMeterView.swift  # Stereo peak meter
│           ├── PhosphorBurnView.swift # Vectorscope with phosphor burn effect
│           ├── SpectrogramView.swift  # Scrolling waterfall spectrogram
│           ├── VectorscopeView.swift  # XY vectorscope
│           └── WaveformView.swift     # Per-voice waveform scopes
├── Tests/
│   ├── SIDEngineTests/
│   │   ├── PSIDHeaderTests.swift    # Header parsing (magic bytes, field extraction)
│   │   └── SonglengthsTests.swift   # SONGLENGTHS.md5 parsing
│   └── SIDCatalogTests/
│       ├── CatalogDBTests.swift     # DB insert, search, upsert, playlist
│       └── HVSCIndexerTests.swift   # Synthetic HVSC tree indexing
├── project.yml              # XcodeGen spec — edit this, not .xcodeproj
├── Package.swift            # SPM manifest (SIDEngine, SIDCatalog, CLI targets)
└── scripts/
    ├── install.sh           # Build Release + install to /Applications
    ├── dmg.sh               # Package into a distributable DMG
    └── notarize.sh          # Apple notarization workflow
```

---

## Architecture

### Layer overview

```
libsidplayfp.a (C++)
      │
CSIDEngine  (ObjC++ bridge)
      │
SIDEngine   (Swift: SIDPlayer, SIDExporter, PSIDHeader, Songlengths, RingBuffer, VizTap)
      │
SIDCatalog  (Swift: CatalogDB/GRDB, HVSCDownloader, HVSCIndexer, HVSCSource, STIL)
      │
App         (SwiftUI: AppState → Views)
```

### Key data flow

- **Playback**: `AppState.selectedID` (didSet) → `AppState.play(tuneID:)` → `SIDPlayer.load(path:)` + `SIDPlayer.play()` → producer thread feeds `RingBuffer` → `AVAudioSourceNode` drains it on the audio render thread → `VizTap` captures PCM for visualizers.
- **Catalog search**: `AppState.searchQuery` / filter state → `CatalogDB.search(...)` (SQL, off main thread) → `AppState.rows` → `AppState.sortedRows` → `TrackListView`.
- **Play queue**: Snapshot of `sortedRows` taken on every user-initiated track selection. Skip/auto-advance operate on this snapshot, not the live view, so tab-switching mid-playback doesn't break navigation.
- **HVSC bootstrap**: `FirstRunView` → `HVSCDownloader` (async stream of `Phase`) → extracted to App Support → `HVSCIndexer` upserts ~55k tunes into SQLite.

### AppState

`AppState` is the single `@Observable` @`MainActor` object injected at the root. All UI state and business logic live here. Views read from it directly and call its `async` methods for mutations. Do not introduce a second state object or split state across multiple `ObservableObject`s — keep it consolidated.

### SIDPlayer threading model

- **Main thread**: `AppState` calls `load()`, `play()`, `pause()`, `stop()`, `select(song:)`.
- **Producer thread** (`sid-producer`, `.userInitiated` QoS): calls the SID emulator in a tight loop, writes Int16 PCM to `RingBuffer`. Also drives the three per-voice engines when `vizEnabled` is true (roughly 3× CPU cost — worth knowing when profiling).
- **Audio render thread** (real-time): `AVAudioSourceNode` callback drains `RingBuffer` → writes Float32 to AVAudioEngine → feeds `VizTap`.
- **Do not** call `SIDPlayerEngine` from the main thread while the producer is running. Always `stopProducer()` before touching engine state.

### Database

- SQLite file in `~/Library/Application Support/SIDPlayer/catalog.sqlite`.
- Tables: `tunes` (one row per .sid file), `lengths` (per-subtune durations), `playlists`, `playlist_tunes`, `play_history`.
- Tune IDs (`Int64`) are stable across re-indexes (upsert by path, not clear-and-reinsert). Playlist and history foreign keys rely on this.
- GRDB is used for all DB access. Use `dbQueue.write { ... }` / `dbQueue.read { ... }` patterns from existing code; do not open raw SQLite handles.

---

## Critical constraints

### Never modify
- `Sources/CSIDEngine/Vendor/lib/libsidplayfp.a` — prebuilt arm64 static archive; rebuilding it requires the full libsidplayfp toolchain.
- `Sources/CSIDEngine/Vendor/include/` — vendored C++ headers matching the archive.
- `App/ROMs/` — bundled C64 ROM images; redistribution constraints apply.

### Never edit `.xcodeproj` directly
The Xcode project is generated from `project.yml` via `xcodegen generate`. Hand-editing `.xcodeproj` will be overwritten. Make structural changes (new files, build settings, schemes) in `project.yml`.

### App Sandbox
The app runs under macOS App Sandbox. This means:
- No shelling out to system binaries (hence SWCompression for 7z instead of `/usr/bin/tar`).
- HVSC directory access requires a security-scoped bookmark (see `HVSCBookmark.swift`).
- Network access is allowed (needed for HVSC download).
- Do not add entitlements without understanding the sandbox impact.

### arm64 only
`libsidplayfp.a` is arm64-only. The project will not build for x86_64 or as a universal binary without rebuilding the archive.

### Deployment target
macOS 14.0 (Sonoma). Do not use APIs introduced after 14.0 without a `@available` guard.

---

## Coding conventions

- **Swift 5.9**, strict concurrency is not yet enforced but avoid new `@unchecked Sendable` unless you understand the existing threading model.
- **SwiftUI + `@Observable`** for all new UI. Do not use `ObservableObject` / `@Published` — the codebase has migrated to the `Observation` framework macro.
- **No third-party UI frameworks**. The only dependencies are GRDB (database) and SWCompression (7z). Do not add new package dependencies without a strong reason.
- **Error handling**: propagate errors with `throws`; surface to the user via `AppState.lastError` or inline UI feedback. Do not silently swallow errors in non-viz code paths.
- **Naming**: follow Swift API design guidelines. Existing public types use descriptive noun names (`TuneRow`, `CatalogDB`, `HVSCSource`). Do not abbreviate.
- **Comments**: the codebase has detailed inline comments explaining non-obvious threading decisions and emulator quirks. Preserve and extend them for any non-trivial addition.

---

## Tests

Tests live under `Tests/` and use Swift Testing (no XCTest). Run with `swift test`.

- `SIDEngineTests` — unit tests for pure-Swift parsing logic (no audio hardware needed).
- `SIDCatalogTests` — in-memory SQLite; use `CatalogDB(inMemory: true)` pattern from existing tests.
- Tests that need real .sid fixture files check for their presence and skip gracefully if absent (HVSC redistribution constraints).
- Do not add tests that require a network connection or a live HVSC installation.

When adding a feature, add or extend tests in the nearest matching test file. Do not create new test files unless adding a new target-level module.

---

## Known pitfalls

- **Double-trigger guard**: `AppState.selectedID.didSet` is the sole playback trigger. Don't call `play()` directly from a view — set `selectedID` instead.
- **Sort performance**: sorting 55k+ `TuneItem`s on the main thread was a prior bottleneck. The `.all` browse mode delegates sorting to SQL (`ORDER BY`). Other modes sort on a background task with generation tagging (`sortGen`) to discard stale results.
- **Search debounce**: `searchQuery` changes are debounced in `AppState` before hitting the DB. Don't add additional debounce in views.
- **Playlist / history IDs**: tune IDs must remain stable across re-index. The indexer upserts by `path`; do not change this to a clear-and-reinsert strategy.
- **Voice engines cost**: the three per-voice `SIDPlayerEngine` instances each run a full C64 emulation ahead of audio output. Disabling visualizers (`vizEnabled = false`) is the only way to reclaim that CPU. Keep this in mind when adding any visualizer-adjacent feature.
- **STIL loading**: `AppState.stil` is lazily loaded the first time the STIL popover opens, not at startup. Do not assume it is populated.

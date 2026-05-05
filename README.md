# SID Player

A native macOS player for the [High Voltage SID Collection](https://hvsc.c64.org/) — Commodore 64 music for the masses.

Built on [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp) for cycle-accurate emulation, with a SwiftUI front-end that browses the entire ~60,000-tune HVSC catalog, plays per-voice oscilloscope traces in lockstep with the audio, and reads HVSC's STIL annotations as a scrolling C64-style marquee.

> **Status:** working, polished, but unsigned and pre-1.0. Built for personal use; happy to take pull requests.

---

## Features

- **One-click HVSC bootstrap.** Discovers the latest release via `hvsc.c64.org/api/v1/version/7z`, downloads the ~640 MB archive, extracts via the system `tar` (libarchive handles 7z natively on macOS), parses every `.sid` header into a SQLite catalog, and matches each tune to its HVSC `Songlengths.md5` entry.
- **Three-tab catalog browser**: All (1000-row preview, FTS5 full-text search), Favorites (★ persisted via UserDefaults), Browse (HVSC directory tree with breadcrumb navigation).
- **Sortable, themed track list** with title, composer, year, subtune count, and duration columns.
- **Per-voice oscilloscope** — three additional libsidplayfp instances run in lockstep with the main engine, each with two voices muted, feeding three colored waveform traces. Audio path is independent so a viz-engine failure can't break sound.
- **Winamp-style 40-band peak meter** with vDSP FFT, log-spaced bands from 50 Hz to 12 kHz, and decaying peak caps.
- **STIL scroller** — HVSC's annotations (sample sources, composer notes, "reused in Wizball" trivia) scroll right-to-left in your theme's accent color, locked to the display refresh.
- **Per-voice mute** — V1/V2/V3 toggles in the transport bar mute individual SID voices.
- **Subtune navigation** — smart prev/next: cycles within a multi-subtune tune, jumps between tracks for single-subtune tunes. Auto-advances at song-length end.
- **8 VSCode-inspired themes** — System Default, Nord, Tokyo Night, Dracula, Gruvbox Dark, Catppuccin Mocha, Solarized Dark, Monokai. Theme tokens reach the title bar, visualizers, peak gradient, voice colors, scroller text, and chrome.

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Xcode 15+** and Apple Silicon or Intel Mac
- **Homebrew** for the libsidplayfp dependency (development only)
- ~1 GB disk space for HVSC

---

## Building from source

```bash
brew install libsidplayfp pkg-config xcodegen
git clone https://github.com/xrayzsoftware/sidplayer.git
cd sidplayer
xcodegen generate
xcodebuild -project SIDPlayer.xcodeproj -scheme SIDPlayer -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/SIDPlayer-*/Build/Products/Debug/SID\ Player.app
```

Or open `SIDPlayer.xcodeproj` in Xcode after running `xcodegen generate`, hit ⌘R.

### CLI tools

The repo also produces three CLI binaries via SwiftPM:

```bash
swift build
swift run sidspike Tests/Fixtures/Commando.sid 10        # play a .sid for 10s
swift run sidcat download                                # bootstrap HVSC
swift run sidcat index                                   # rebuild the catalog
swift run sidcat search "rob hubbard"                    # FTS5 search
swift run sidcat info <id>                               # full metadata
swift run sidcat play <id> 30                            # play by catalog ID
```

The CLIs share the same engine and catalog as the GUI app — useful for headless testing.

### Tests

```bash
swift test
```

21 tests covering PSID/RSID header parsing (incl. v2+ flag bits → clock/model), HVSC `Songlengths.md5` parser (including CRLF + `[Database]` header regression cases), and end-to-end indexer behavior against a synthetic HVSC tree.

---

## Architecture

```
sidplayer/
├── App/                              SwiftUI app (Xcode target)
│   ├── SIDPlayerApp.swift            @main + window tinting
│   ├── AppState.swift                @Observable state, persistence
│   ├── ContentView.swift             top-level layout
│   ├── Theme.swift                   AppTheme + 8 presets
│   ├── TuneItem.swift                view-model wrapper for TuneRow
│   ├── AppIcon.icns                  10-size icon, hand-built via iconutil
│   └── Views/                        all subviews
│       └── Visualizers/              waveform + peak meter
│
├── Sources/
│   ├── CSIDEngine/                   Obj-C++ bridge over libsidplayfp
│   │   ├── include/CSIDEngine.h      pure Obj-C public API for Swift
│   │   └── CSIDEngine.mm             Obj-C++ wrapping sidplayfp + SidTune
│   │
│   ├── SIDEngine/                    Pure-Swift player core
│   │   ├── SIDEngine.swift           Swift wrapper over the bridge
│   │   ├── SIDPlayer.swift           AVAudioEngine + producer thread
│   │   ├── PSIDHeader.swift          PSID/RSID v1-v4 parser (no libsidplayfp)
│   │   ├── Songlengths.swift         HVSC Songlengths.md5 parser
│   │   ├── RingBuffer.swift          SPSC Int16 audio FIFO
│   │   └── VizTap.swift              latest-N-samples non-FIFO buffer
│   │
│   ├── SIDCatalog/                   Catalog + indexing (depends on GRDB)
│   │   ├── CatalogDB.swift           Schema, migrations, FTS5
│   │   ├── HVSCSource.swift          Validated HVSC root
│   │   ├── HVSCDownloader.swift      URLSession + tar extraction
│   │   ├── HVSCIndexer.swift         Walk → parse → md5 → insert
│   │   └── STIL.swift                HVSC STIL.txt parser
│   │
│   ├── sidspike/                     CLI: play a single .sid
│   └── sidcat/                       CLI: catalog management
│
└── Tests/                            XCTest suites
    ├── SIDEngineTests/               PSID + Songlengths parsers
    └── SIDCatalogTests/              CatalogDB + Indexer end-to-end
```

### Audio path

```
                            ┌────────────────────────────────────────────┐
                            │  AVAudioEngine source node (audio thread)  │
                            │  ────────────────────────────────────────  │
                            │  drains main RingBuffer  → Float32 output  │
                            │  also writes to main VizTap (peak meter)   │
                            └─────────────────▲──────────────────────────┘
                                              │ pulls 1024 samples/call
                                              │
┌───────────────────────────────────┐         │
│  Producer thread (.userInitiated) │ ────────┘
│  ─────────────────────────────    │
│  loop:                            │
│    main engine.render()  → ring   │   ┌────────────────────┐
│    voice0 engine.render() ─┐      │   │  Voice VizTaps × 3 │
│    voice1 engine.render() ─┼──────┼──▶│  (peek-the-latest) │
│    voice2 engine.render() ─┘      │   └─────────▲──────────┘
└───────────────────────────────────┘             │
                                                  │ snapshotFloats(1024) every frame
                                        ┌─────────┴──────────┐
                                        │  WaveformView      │
                                        │  (3 stacked panels)│
                                        └────────────────────┘
```

- Main libsidplayfp engine drives the audible mix
- Three additional engines run the same tune with two voices muted each, in lockstep, feeding the per-voice waveform display
- Ring buffer is 4 096 samples (~93 ms at 44.1 kHz) — small enough that visual lag is imperceptible, large enough that the producer thread can keep up
- Voice engine failures cannot block the main audio path: render results that come back zero are silently dropped

### Why an Obj-C++ bridge?

libsidplayfp is C++. Swift can't import C++ directly with full fidelity (no class-method support across language barriers in stable Swift). Wrapping it in an Obj-C++ `.mm` file with a pure-Obj-C `.h` interface lets Swift use it as a normal `NSObject`. The bridge stays small (~150 LoC) and only exposes what the Swift layer actually needs.

---

## Known limitations

- **All-tab is capped at 1000 rows.** SwiftUI `Table` Debug-build sort on 60k items takes seconds. A Release build is ~5–10× faster, and a future LazyVStack-based custom list would lift the cap entirely.
- **No app sandboxing.** Disabled during development so HVSC files can live anywhere. App Sandbox + entitlements are a TODO before any kind of distribution.
- **Distribution license:** libsidplayfp is GPLv2. Linking it makes any distributed binary GPL. Fine for a personal build; matters if you ever want to ship commercially.
- **C64 ROM images** (KERNAL/BASIC/CHARGEN) are not bundled. Most PSID tunes don't need them; some RSID tunes will fail to play. Bundling open-source replacements (from VICE) is on the roadmap.
- **Title-bar text contrast** on lighter themes (Solarized Light, etc.) can be off — macOS computes the title color from the window appearance rather than your theme palette.

---

## Acknowledgements

- **High Voltage SID Collection** team — the canonical archive of C64 music ([hvsc.c64.org](https://hvsc.c64.org)).
- **libsidplayfp** authors (Leandro Nini, Antti Lankila, Simon White) — the engine that does all the actual emulation.
- **GRDB.swift** by Gwendal Roué — the SQLite wrapper used for the catalog.
- The original C64 composers — Rob Hubbard, Martin Galway, Jeroen Tel, Jonathan Dunn, Jason Page, Chris Hülsbeck, and the rest of the SID pantheon. This player exists because their music does.

---

## License

Source code in this repository: MIT.
Linked at runtime: libsidplayfp (GPLv2). Distributing built binaries therefore requires GPL compliance.

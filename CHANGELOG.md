# Changelog

All notable changes to SID Player. Releases are signed and notarized DMGs for Apple silicon (macOS 14+), attached to each [GitHub release](https://github.com/xrayzsoftware/sidplayer/releases).

## 0.11 — 2026-09-18

Second stability pass. Fixes a 0.10 regression that broke first-run onboarding.

### Fixed
- **Download HVSC now indexes** — in 0.10 the download finished, then silently skipped indexing and sat on a full progress bar with no way out. Fresh installs were stuck.
- **Re-indexing can no longer wipe the catalog** — an unreadable directory (dropped external volume, wrong folder) used to be treated as "all tunes gone" and cascade-deleted playlists, play history and play counts. The indexer now aborts on a read error and refuses the delete if it saw fewer than half the catalogued tunes.
- **Spectrum visualizers were an octave off** — the FFT input was packed incorrectly, so every band showed content an octave below its label and the top half of the range was mirrored noise.
- **Cancel** — downloads and re-indexes can now be cancelled from the first-run screen and Settings.
- **MIDI export** captured fast arpeggios incorrectly at high play rates (consecutive register snapshots read the same emulator state).
- **Subtune changes** no longer rebuild the whole SID emulation four times on the main thread.
- Switching tabs while a column sort was running could fill the new tab with the old tab's rows.
- Late indexing progress updates could flip a finished catalog back to "indexing".
- Arrow-key navigation in the track list no longer loads and records every row passed over (playback starts after a short pause on the selected row).
- Playback start stalls less on tunes that fail to render.
- Unparseable Songlengths entries no longer shift later subtunes' lengths.
- A failed subtune switch no longer plays a burst of the previous song.
- STIL scroller no longer redraws at display rate while idle.
- Spectrogram draws far fewer paths per frame.

## 0.10 — 2026-09-14

Stability release from a full code review. No new features.

### Fixed
- **Play after Stop works again** — the time counter, auto-advance, repeat, shuffle and Control Center all died after pressing Stop.
- **No start-up gap** — the audio buffer is primed before the engine starts.
- **Stop lets you replay the same row.**
- **Browse mode Next follows the visible list** instead of an author-sorted neighbour.
- **Shuffle + repeat-one** walks a tune's subtunes; shuffle on a one-track list with repeat-all replays instead of stopping.
- **Failed HVSC download no longer strands you** — the first-run screen keeps its buttons, Re-index errors show instead of spinning forever, and Download / Re-index can't be started twice.
- **Safer HVSC extraction** — extracts into a staging folder and swaps it in only after validation.
- Re-indexing an unchanged collection no longer rewrites the whole search index.
- Opening a second window (⌘N) no longer opens a second database or leaks a security-scope grant.
- Tune header strings decoded as Latin-1, so accented author names show correctly.
- Subtune number reported by the engine reflects what actually plays.
- Corrupt Songlengths entries are skipped instead of crashing the indexer; MIDI export is bounded on digi tunes.
- CSDb "not found" results expire after a week.
- Mini player restores only the windows it hid.
- Subtune stepper resets the elapsed time and is disabled while stopped; Play with nothing loaded is a no-op.

## 0.9 — 2026-07-09

### Changed
- **Shuffle always moves to a new tune** — Next/Prev and end-of-song auto-advance pick a fresh track instead of cycling through a tune's subtunes.
- **Dedicated subtune controls** — the transport bar's subtune counter gained ‹ › steppers.
- Next/Prev in the transport bar, mini player and media keys always mean previous/next *track*; sequential playback still plays all subtunes before advancing.

## 0.8 — 2026-07-08

### Added
- **Shuffle follows the list** — with shuffle on, the track list scrolls to the song that just started playing and re-syncs when you return to the tab.

## 0.7 — 2026-07-02

Stability and correctness release from a full code review.

### Fixed
- **WAV export is atomic** — a failed export can no longer destroy an existing file; both exporters report an error instead of writing a truncated file if the emulator stops early.
- **CSDb lookups** no longer permanently cache "not found" for tunes whose entry lacks an HVSC path tag.
- **Playback state is always truthful** — errors during play/pause, track load or subtune switches surface in the UI.
- Playback clock is published from the audio producer thread instead of racing it.
- **MIDI export** — drums from all voices share one percussion track with overlap merging.
- Folder browsing treats underscores in HVSC directory names literally.
- 3SID tunes with minimal PSID v4 headers report all three chips.
- CSDb panel refreshes when auto-advance changes the track while it's open.
- Peak meter no longer redraws at 60 Hz while idle; mini player no longer queries the database 10× per second.

### Tests
- New coverage: WAV header layout and end-to-end export, MIDI percussion merging, minimal v4 headers, malformed register images, browse wildcard escaping.

## 0.6 — 2026-06-19

### Added
- **Export as MIDI** — right-click any tune to transcribe its SID register activity to a Standard MIDI File. Each SID voice becomes its own track; noise voices go to GM percussion.

### Fixed
- **CSDb lookups match the right tune** — matches are verified against CSDb's own HVSC path. Transient outages show a Retry instead of a false "not found".

## 0.5 — 2026-06-18

### Added
- **Now Playing + media keys** — Control Center, the menu-bar widget, the lock screen and F7/F8/F9, including AirPods/Bluetooth transport buttons.
- **Most-Played tab** — tunes ranked by cumulative play count, tracked in a table that survives history pruning.
- **CSDb panel** — resolves the playing tune to its csdb.dk entry and lists the demoscene releases it appears in.
- Volume persists across launches.

## 0.4 — 2026-06-17

### Added
- **SID register monitor** visualizer — live $D400–$D418 state: per-voice note and cents, waveform, gate, pulse width, ADSR, filter and volume.
- **reSIDfp engine + filter tuning** — full-quality analog SID emulation bundled; Settings gains an Engine picker and 6581/8580 filter-curve sliders. reSIDfp is the default audible engine.

## 0.3 — 2026-06-16

Maintenance release from a code audit of the audio engine, view models and visualizers.

### Fixed
- **WAV export length** — a tune with no songlength entry no longer borrows the playing tune's duration.
- **Visualizers pause cleanly** when playback is stopped.
- **STIL scroller** caches its text instead of reading SQLite every animation tick.
- **HVSC folder switching** releases the previous folder's security-scoped access.
- **Audio real-time safety** — per-voice visualizer taps use a non-blocking write.

## 0.2 — 2026-06-10

### Added
- **Mini Player** — compact always-on-top window.
- **Export as WAV** — render any subtune offline to 44.1 kHz 16-bit WAV.

### Fixed
- Search no longer errors on NOT, AND or OR.
- Re-indexing can no longer drop tunes when a file momentarily fails to read.
- Audio render thread no longer takes locks.
- WAV export surfaces disk errors.
- PSID v2 files with junk in a reserved header byte no longer show a phantom second SID.
- Failed HVSC downloads no longer leak a temp file.
- Peak meter decays to silence when paused.
- Faster search, batched indexing, chunked downloads, stable play queue.

## 0.1 — 2026-05-31

Initial release. Native macOS player for the High Voltage SID Collection: per-voice oscilloscopes, FTS5 catalog search, shuffle/repeat, play history and playlists. Apple silicon only, macOS 14+. On first run the app can download and index the HVSC archive.

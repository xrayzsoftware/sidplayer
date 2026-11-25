import XCTest
@testable import SIDEngine

/// Unit tests for the SID → MIDI note tracker and the SMF byte writer. These
/// drive the pure transcription logic with synthetic register frames, so they
/// encode *why* each behaviour matters (gate = note boundary, pitch change =
/// new note, sub-threshold notes are flicker) independent of any live engine.
final class SIDMIDIExporterTests: XCTestCase {

    // A4 = 440 Hz on PAL: Freg = 440 · 2²⁴ / cpuHz.
    private func freqReg(forHz hz: Double, clock: SIDRegisters.Clock = .pal) -> UInt16 {
        UInt16((hz * 16_777_216.0 / clock.cpuHz).rounded())
    }

    /// Builds a single-voice register image with the given frequency, gate, and
    /// (pulse) waveform. Sustain defaults high so velocity is non-trivial.
    private func voiceImage(freq: UInt16, gate: Bool, pulse: Bool = true,
                            noise: Bool = false, sustain: UInt8 = 15) -> [UInt8] {
        var regs = [UInt8](repeating: 0, count: 32)
        regs[0] = UInt8(freq & 0xFF)
        regs[1] = UInt8(freq >> 8)
        var control: UInt8 = 0
        if gate  { control |= 0x01 }
        if pulse { control |= 0x40 }
        if noise { control |= 0x80 }
        regs[4] = control
        regs[6] = sustain << 4          // sustain nibble (high), release 0
        return regs
    }

    private func voices(_ image: [UInt8]) -> [SIDRegisters.Voice] {
        SIDRegisters(image: image).voices
    }

    // MARK: - Note boundaries

    func testGateOpenToCloseProducesOneNote() {
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        let a4 = freqReg(forHz: 440)
        // 5 frames sounding, then gate released.
        for f in 0..<5 { tracker.step(frame: f, voices: voices(voiceImage(freq: a4, gate: true))) }
        tracker.step(frame: 5, voices: voices(voiceImage(freq: a4, gate: false)))
        tracker.finish(endFrame: 6)

        XCTAssertEqual(tracker.notes.count, 1, "one continuous gated tone = one note")
        let n = tracker.notes[0]
        XCTAssertEqual(n.key, 69, "440 Hz must round to MIDI 69 (A4)")
        XCTAssertEqual(n.startFrame, 0)
        XCTAssertEqual(n.endFrame, 5, "note ends the frame the gate dropped")
        XCTAssertEqual(n.channel, 0, "voice 0 → channel 0")
    }

    func testPitchChangeWhileGatedSplitsNotes() {
        // The whole point of the literal transcription: a new rounded pitch
        // under a held gate is a new note (covers slides and arpeggios).
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        let a4 = freqReg(forHz: 440)
        let c5 = freqReg(forHz: 523.25)
        for f in 0..<3 { tracker.step(frame: f, voices: voices(voiceImage(freq: a4, gate: true))) }
        for f in 3..<6 { tracker.step(frame: f, voices: voices(voiceImage(freq: c5, gate: true))) }
        tracker.finish(endFrame: 6)

        XCTAssertEqual(tracker.notes.count, 2)
        XCTAssertEqual(tracker.notes[0].key, 69)
        XCTAssertEqual(tracker.notes[1].key, 72, "523.25 Hz → C5 = MIDI 72")
        XCTAssertEqual(tracker.notes[0].endFrame, 3)
        XCTAssertEqual(tracker.notes[1].startFrame, 3)
    }

    func testVibratoWithinSemitoneStaysOneNote() {
        // ±~30 cents wobble must round to the same key → no machine-gun notes.
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        let center = 440.0
        for f in 0..<8 {
            let hz = center * (f % 2 == 0 ? 1.015 : 0.985)   // ~±26 cents
            tracker.step(frame: f, voices: voices(voiceImage(freq: freqReg(forHz: hz), gate: true)))
        }
        tracker.finish(endFrame: 8)
        XCTAssertEqual(tracker.notes.count, 1, "sub-semitone vibrato is a single sustained note")
        XCTAssertEqual(tracker.notes[0].key, 69)
    }

    // MARK: - Flicker filtering

    func testMinNoteFramesDropsShortFlicker() {
        var opts = MIDIExportOptions(); opts.minNoteFrames = 2
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: opts)
        let a4 = freqReg(forHz: 440)
        // One-frame blip (gate on f0, off f1) — shorter than the 2-frame floor.
        tracker.step(frame: 0, voices: voices(voiceImage(freq: a4, gate: true)))
        tracker.step(frame: 1, voices: voices(voiceImage(freq: a4, gate: false)))
        tracker.finish(endFrame: 2)
        XCTAssertTrue(tracker.notes.isEmpty, "a 1-frame note must be dropped at minNoteFrames=2")
    }

    func testMinNoteFramesOneKeepsEverything() {
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        let a4 = freqReg(forHz: 440)
        tracker.step(frame: 0, voices: voices(voiceImage(freq: a4, gate: true)))
        tracker.step(frame: 1, voices: voices(voiceImage(freq: a4, gate: false)))
        tracker.finish(endFrame: 2)
        XCTAssertEqual(tracker.notes.count, 1, "default (literal) keeps even a 1-frame note")
    }

    // MARK: - Percussion routing

    func testNoiseRoutesToPercussionChannel() {
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        // Low-frequency noise → bass drum (key 36) on channel 9.
        let lowNoise = freqReg(forHz: 200)
        for f in 0..<4 {
            tracker.step(frame: f, voices: voices(voiceImage(freq: lowNoise, gate: true,
                                                             pulse: false, noise: true)))
        }
        tracker.finish(endFrame: 4)
        XCTAssertEqual(tracker.notes.count, 1)
        XCTAssertEqual(tracker.notes[0].channel, 9, "noise → GM percussion channel 10 (0-based 9)")
        XCTAssertEqual(tracker.notes[0].key, 36, "low band → bass drum")
    }

    func testNoiseStaysTonalWhenPercussionDisabled() {
        var opts = MIDIExportOptions(); opts.noiseToPercussion = false
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: opts)
        for f in 0..<4 {
            tracker.step(frame: f, voices: voices(voiceImage(freq: freqReg(forHz: 440),
                                                             gate: true, pulse: false, noise: true)))
        }
        tracker.finish(endFrame: 4)
        XCTAssertEqual(tracker.notes.count, 1)
        XCTAssertEqual(tracker.notes[0].channel, 0, "with the option off, noise stays on its voice channel")
    }

    // MARK: - Velocity

    func testVelocityTracksSustain() {
        let tracker = SIDNoteTracker(voiceCount: 3, clock: .pal, options: MIDIExportOptions())
        let a4 = freqReg(forHz: 440)
        for f in 0..<3 {
            tracker.step(frame: f, voices: voices(voiceImage(freq: a4, gate: true, sustain: 15)))
        }
        tracker.finish(endFrame: 3)
        XCTAssertEqual(tracker.notes[0].velocity, 127, "full sustain (15) maps to max velocity")
    }

    // MARK: - Percussion merging

    func testMergedPercussionJoinsOverlappingSameKeyHits() {
        // Two voices hitting the same drum with overlapping spans: kept apart
        // they'd share channel 9 and the first note-off would cut the second
        // hit short. The merge must yield one union-span note.
        let a = TranscribedNote(channel: 9, key: 36, velocity: 100,
                                startFrame: 0, endFrame: 6, voiceIndex: 0)
        let b = TranscribedNote(channel: 9, key: 36, velocity: 127,
                                startFrame: 4, endFrame: 10, voiceIndex: 1)
        let merged = mergedPercussion([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startFrame, 0)
        XCTAssertEqual(merged[0].endFrame, 10, "merged note spans the union")
        XCTAssertEqual(merged[0].velocity, 127, "loudest hit wins")
    }

    func testMergedPercussionKeepsDistinctHits() {
        // Different keys, and same-key hits that don't overlap, stay separate.
        let kick1 = TranscribedNote(channel: 9, key: 36, velocity: 100,
                                    startFrame: 0, endFrame: 2, voiceIndex: 0)
        let kick2 = TranscribedNote(channel: 9, key: 36, velocity: 100,
                                    startFrame: 5, endFrame: 7, voiceIndex: 1)
        let snare = TranscribedNote(channel: 9, key: 38, velocity: 100,
                                    startFrame: 1, endFrame: 3, voiceIndex: 2)
        XCTAssertEqual(mergedPercussion([kick1, kick2, snare]).count, 3)
    }

    func testPercussionNotesGetOwnSharedTrack() {
        // One tonal voice + one drum → tempo + voice track + percussion track.
        let notes = [
            TranscribedNote(channel: 0, key: 69, velocity: 100,
                            startFrame: 0, endFrame: 25, voiceIndex: 0),
            TranscribedNote(channel: 9, key: 36, velocity: 100,
                            startFrame: 0, endFrame: 5, voiceIndex: 0),
        ]
        let data = buildSMF(notes: notes, voiceCount: 1, programs: [80], playRateHz: 50)
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[10..<12]), [0, 3], "MThd track count = 3")
        XCTAssertEqual(occurrences(of: Array("MTrk".utf8), in: bytes), 3)
    }

    // MARK: - SMF bytes

    func testSMFHeaderAndStructure() {
        let notes = [TranscribedNote(channel: 0, key: 69, velocity: 100,
                                     startFrame: 0, endFrame: 25, voiceIndex: 0)]
        let data = buildSMF(notes: notes, voiceCount: 1, programs: [80], playRateHz: 50)
        let bytes = [UInt8](data)

        XCTAssertEqual(Array(bytes[0..<4]), Array("MThd".utf8))
        // MThd length = 6.
        XCTAssertEqual(Array(bytes[4..<8]), [0, 0, 0, 6])
        // format 1, 2 tracks (tempo + 1 voice), division 480 (0x01E0).
        XCTAssertEqual(Array(bytes[8..<14]), [0, 1, 0, 2, 0x01, 0xE0])
        // First chunk after the 14-byte header is an MTrk.
        XCTAssertEqual(Array(bytes[14..<18]), Array("MTrk".utf8))
        // The full file must contain exactly two MTrk chunks.
        XCTAssertEqual(occurrences(of: Array("MTrk".utf8), in: bytes), 2)
    }

    func testVLQEncoding() {
        XCTAssertEqual(smfVLQ(0), [0x00])
        XCTAssertEqual(smfVLQ(127), [0x7F])
        XCTAssertEqual(smfVLQ(128), [0x81, 0x00])     // canonical multi-byte VLQ
        XCTAssertEqual(smfVLQ(192), [0x81, 0x40])
    }

    // MARK: - End to end

    func testExportFixtureProducesValidMIDIWithNotes() throws {
        let fixture = URL(fileURLWithPath: "Tests/Fixtures/Commando.sid")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Tests/Fixtures/Commando.sid not present (gitignored)")
        }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commando-export-\(getpid()).mid")
        defer { try? FileManager.default.removeItem(at: dest) }

        // 4 s is plenty of melody without a slow test; PSID needs no ROMs.
        try exportSIDToMIDI(path: fixture.path, song: 1, durationMs: 4000,
                            sampleRate: 44100, config: EmulationConfig(), to: dest)

        let bytes = [UInt8](try Data(contentsOf: dest))
        XCTAssertEqual(Array(bytes[0..<4]), Array("MThd".utf8), "must start with a MIDI header")
        // 5 tracks: tempo + 3 voices + percussion (Commando's bass voice
        // plays noise drums, which route to the shared percussion track).
        XCTAssertEqual(occurrences(of: Array("MTrk".utf8), in: bytes), 5)

        // Count note-on events (0x9n status with non-zero velocity). A real tune
        // must yield some; zero would mean the register sampling never fired.
        var noteOns = 0
        for b in bytes where b & 0xF0 == 0x90 { noteOns += 1 }
        XCTAssertGreaterThan(noteOns, 10, "4 s of Commando should transcribe many notes")
    }

    // MARK: - Play rate

    /// The steps (0.1 ms each) at which registers change for a tune whose
    /// play routine runs every `periodMs` and, on a call that does anything,
    /// writes at `offsetsMs` into it.
    private func changeSteps(periodMs: Double, offsetsMs: [Double] = [0], calls: Int,
                             active: (Int) -> Bool = { _ in true }) -> [Int] {
        var steps: [Int] = []
        for call in 0..<calls where active(call) {
            for offset in offsetsMs {
                steps.append(Int(((Double(call) * periodMs + offset) / 0.1).rounded()))
            }
        }
        return steps
    }

    func testPlaySpeedIgnoresWritesSpreadWithinOneCall() {
        // A single-speed routine that takes its time: voice by voice, 1.2 ms
        // apart, once per 20 ms frame. Those short distances are not a play
        // rate — nothing follows them at twice and three times the distance —
        // and sampling such a tune faster only catches it half-updated.
        let steps = changeSteps(periodMs: 20, offsetsMs: [0, 1.2, 2.4], calls: 250)
        XCTAssertEqual(playSpeed(changeSteps: steps, stepMs: 0.1, frameHz: 50), 1)
    }

    func testPlaySpeedSeesThroughPausesBetweenBusyStretches() {
        // A 4x tune (5 ms) that often leaves its registers alone for a few
        // calls: after each change the next comes 1, 2, 3, 4 or 8 calls
        // later, as measured on a real 4x tune. Most of the time passes in
        // the pauses — only a fifth of it between changes one call apart —
        // but those are what the transcription has to keep up with.
        var call = 0
        var active: Set<Int> = []
        var seed: UInt32 = 12345
        while call < 2000 {
            active.insert(call)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let roll = Int(seed >> 16) % 100
            call += roll < 55 ? 1 : roll < 65 ? 2 : roll < 75 ? 3 : roll < 87 ? 4 : 8
        }
        let steps = changeSteps(periodMs: 5, calls: 2000) { active.contains($0) }
        XCTAssertEqual(playSpeed(changeSteps: steps, stepMs: 0.1, frameHz: 50), 4)
    }

    func testPlaySpeedDoublesForASixtyHertzTuneOnAFiftyHertzFrame() {
        // The PSID default for a timer-driven tune is 60 calls a second, on
        // PAL too. Sampled at the 50 Hz frame rate, a call in six is skipped.
        let steps = changeSteps(periodMs: 1000.0 / 60, calls: 300)
        XCTAssertEqual(playSpeed(changeSteps: steps, stepMs: 0.1, frameHz: 50), 2)
        XCTAssertEqual(playSpeed(changeSteps: steps, stepMs: 0.1, frameHz: 60), 1)
    }

    func testPlaySpeedIsOneWhenThereIsTooLittleToGoOn() {
        XCTAssertEqual(playSpeed(changeSteps: [], stepMs: 0.1, frameHz: 50), 1)
        XCTAssertEqual(playSpeed(changeSteps: changeSteps(periodMs: 5, calls: 6), stepMs: 0.1, frameHz: 50), 1)
    }

    /// A minimal PSID that plays at four times the frame rate: its init sets
    /// CIA timer A to 200 Hz (PAL), and its play routine moves voice 1 to the
    /// other of two pitches on every call, under a held gate.
    private func multiSpeedPSID() -> Data {
        var header = [UInt8](repeating: 0, count: 0x7C)
        header.replaceSubrange(0..<4, with: Array("PSID".utf8))
        header[0x05] = 2                        // version
        header[0x07] = 0x7C                     // data offset
        header[0x08] = 0x10                     // load address $1000
        header[0x0A] = 0x10                     // init  $1000
        header[0x0C] = 0x10; header[0x0D] = 0x20 // play  $1020
        header[0x0F] = 1                        // songs
        header[0x11] = 1                        // start song
        header[0x15] = 1                        // speed: song 1 is CIA-timed
        header[0x77] = 0x14                     // flags: PAL, 6581
        let initCode: [UInt8] = [
            0xA9, 0x0F, 0x8D, 0x18, 0xD4,       // LDA #$0F : STA $D418   volume
            0xA9, 0x3D, 0x8D, 0x04, 0xDC,       // LDA #$3D : STA $DC04   timer A = $133D:
            0xA9, 0x13, 0x8D, 0x05, 0xDC,       // LDA #$13 : STA $DC05   985248 / 4926 = 200 Hz
            0xA9, 0x1D, 0x85, 0xFB,             // LDA #$1D : STA $FB     pitch (frequency high byte)
            0xA9, 0xF0, 0x8D, 0x06, 0xD4,       // LDA #$F0 : STA $D406   sustain 15
            0xA9, 0x41, 0x8D, 0x04, 0xD4,       // LDA #$41 : STA $D404   pulse, gate on
            0x60, 0xEA, 0xEA,                   // RTS, padded to $1020
        ]
        let playCode: [UInt8] = [
            0xA5, 0xFB, 0x49, 0x13, 0x85, 0xFB, // LDA $FB : EOR #$13 : STA $FB   $1D <-> $0E
            0x8D, 0x01, 0xD4,                   // STA $D401
            0x60,                               // RTS
        ]
        return Data(header + initCode + playCode)
    }

    /// Every play call of a multi-speed tune must reach the transcription.
    /// Here each call is a new note, so two seconds at 200 Hz hold about 400.
    /// The exporter once took the play rate from the emulator's CIA timer
    /// read — before the tune's init had run, and from a value that does not
    /// follow a timer set only once, as this one is. Every tune was sampled
    /// at the 50 Hz frame rate, which sees this one at the same pitch each
    /// time: a note or two, the other three calls in four lost.
    func testMultiSpeedTuneIsSampledAtItsPlayRate() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let source = tmp.appendingPathComponent("multispeed-\(getpid()).sid")
        let dest = tmp.appendingPathComponent("multispeed-\(getpid()).mid")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try multiSpeedPSID().write(to: source)

        try exportSIDToMIDI(path: source.path, song: 1, durationMs: 2000,
                            sampleRate: 44100, config: EmulationConfig(), to: dest)

        // Frequency high bytes $1D and $0E are 436 Hz and 210 Hz on PAL: MIDI
        // keys 69 and 56. Voice 1 is channel 0; sustain 15 is velocity 127.
        let bytes = [UInt8](try Data(contentsOf: dest))
        let noteOns = occurrences(of: [0x90, 69, 127], in: bytes)
                    + occurrences(of: [0x90, 56, 127], in: bytes)
        XCTAssertGreaterThan(noteOns, 300, "a 200 Hz play routine sampled at the frame rate")
        XCTAssertLessThan(noteOns, 420, "more notes than play calls")
    }

    private func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i+needle.count]) == needle {
            count += 1
        }
        return count
    }
}

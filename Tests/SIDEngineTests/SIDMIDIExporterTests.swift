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
        // 4 tracks: tempo + 3 voices.
        XCTAssertEqual(occurrences(of: Array("MTrk".utf8), in: bytes), 4)

        // Count note-on events (0x9n status with non-zero velocity). A real tune
        // must yield some; zero would mean the register sampling never fired.
        var noteOns = 0
        for b in bytes where b & 0xF0 == 0x90 { noteOns += 1 }
        XCTAssertGreaterThan(noteOns, 10, "4 s of Commando should transcribe many notes")
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

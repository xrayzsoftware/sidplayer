import Foundation

// MARK: - Options

/// Options controlling SID → MIDI transcription. The defaults produce a
/// faithful, literal register trace: every per-frame note is kept (arpeggios
/// included), so the output recognisably reproduces the tune but is not a
/// cleaned-up score.
public struct MIDIExportOptions: Sendable {
    /// Drop notes shorter than this many play-frames. 1 keeps everything
    /// (literal). Raising it denoises gate flicker — but fast arpeggios are
    /// 1-frame notes and would be dropped too, so leave at 1 for faithfulness.
    public var minNoteFrames: Int
    /// Derive note velocity from the voice's sustain level (else a fixed 100).
    public var velocityFromSustain: Bool
    /// Route noise-waveform notes to GM channel 10 (percussion) with a coarse
    /// frequency-band → kick/snare/hat mapping. A noise oscillator has no
    /// meaningful pitch, so this is usually more musical than a tonal key.
    public var noiseToPercussion: Bool

    public init(minNoteFrames: Int = 1,
                velocityFromSustain: Bool = true,
                noiseToPercussion: Bool = true) {
        self.minNoteFrames = minNoteFrames
        self.velocityFromSustain = velocityFromSustain
        self.noiseToPercussion = noiseToPercussion
    }
}

// MARK: - Note tracker

/// One transcribed note. Frame indices are at the tune's play rate; the SMF
/// writer converts them to ticks.
struct TranscribedNote: Equatable {
    var channel: Int        // 0-based MIDI channel (9 = percussion)
    var key: Int            // MIDI note number 0…127
    var velocity: Int       // 1…127
    var startFrame: Int
    var endFrame: Int       // exclusive
    var voiceIndex: Int     // originating SID voice (for per-voice track grouping)
}

/// Turns a per-frame stream of decoded SID voice state into note on/off events.
/// Pure logic over value types — no engine access — so it's directly testable
/// with synthetic frames.
///
/// A voice is "sounding" when its gate is open, it isn't held in test/reset,
/// it has a tone-producing waveform, and its frequency register is non-zero.
/// A note ends when the voice stops sounding *or* its rounded pitch changes
/// (legato / slide / arpeggio all read as a new note — this is the literal
/// transcription, by design).
final class SIDNoteTracker {
    private struct VoiceState {
        var active = false
        var key = 0
        var velocity = 0
        var channel = 0
        var startFrame = 0
    }

    let voiceCount: Int
    private let clock: SIDRegisters.Clock
    private let options: MIDIExportOptions
    private var states: [VoiceState]
    private var waveformTally: [[Int]]   // voiceCount × [pulse, saw, triangle]
    private(set) var notes: [TranscribedNote] = []

    init(voiceCount: Int, clock: SIDRegisters.Clock, options: MIDIExportOptions) {
        self.voiceCount = voiceCount
        self.clock = clock
        self.options = options
        self.states = Array(repeating: VoiceState(), count: voiceCount)
        self.waveformTally = Array(repeating: [0, 0, 0], count: voiceCount)
    }

    /// `voices` is the flat list of every SID voice this frame, chip-major
    /// (chip0 v0,v1,v2, chip1 v0,…). Its count must equal `voiceCount`.
    func step(frame: Int, voices: [SIDRegisters.Voice]) {
        for i in 0..<voiceCount {
            let v = voices[i]
            let sounding = v.gate && !v.test && v.frequency > 0 &&
                (v.triangle || v.sawtooth || v.pulse || v.noise)

            if sounding {
                if v.pulse    { waveformTally[i][0] += 1 }
                if v.sawtooth { waveformTally[i][1] += 1 }
                if v.triangle { waveformTally[i][2] += 1 }
            }

            var key = 0
            var channel = i
            if sounding {
                if v.noise && options.noiseToPercussion {
                    channel = 9
                    key = drumKey(hz: v.frequencyHz(clock: clock))
                } else {
                    key = midiKey(hz: v.frequencyHz(clock: clock))
                }
            }
            let velocity = options.velocityFromSustain
                ? min(127, max(1, Int(v.sustain) * 8 + 7))
                : 100

            var st = states[i]
            if st.active && (!sounding || key != st.key || channel != st.channel) {
                closeNote(&st, voiceIndex: i, endFrame: frame)
            }
            if sounding && !st.active {
                st.active = true
                st.key = key
                st.velocity = velocity
                st.channel = channel
                st.startFrame = frame
            }
            states[i] = st
        }
    }

    /// Closes any still-open notes at the final frame.
    func finish(endFrame: Int) {
        for i in 0..<voiceCount {
            var st = states[i]
            if st.active { closeNote(&st, voiceIndex: i, endFrame: endFrame) }
            states[i] = st
        }
    }

    /// GM program byte for a voice, chosen from its dominant tonal waveform.
    func program(forVoice i: Int) -> UInt8 {
        let t = waveformTally[i]
        let idx = t.indices.max(by: { t[$0] < t[$1] }) ?? 0
        switch idx {
        case 0:  return 80   // Lead 1 (square)
        case 1:  return 81   // Lead 2 (sawtooth)
        default: return 82   // Lead 3 (calliope) — triangle-ish
        }
    }

    private func closeNote(_ st: inout VoiceState, voiceIndex: Int, endFrame: Int) {
        defer { st.active = false }
        guard endFrame - st.startFrame >= options.minNoteFrames else { return }
        notes.append(TranscribedNote(channel: st.channel, key: st.key,
                                     velocity: st.velocity, startFrame: st.startFrame,
                                     endFrame: endFrame, voiceIndex: voiceIndex))
    }

    private func midiKey(hz: Double) -> Int {
        guard hz > 0 else { return 0 }
        let m = (69.0 + 12.0 * log2(hz / 440.0)).rounded()
        return min(127, max(0, Int(m)))
    }

    private func drumKey(hz: Double) -> Int {
        if hz < 400  { return 36 }   // acoustic bass drum
        if hz < 2000 { return 38 }   // acoustic snare
        return 42                    // closed hi-hat
    }
}

// MARK: - Export entry point

/// Renders one subtune of a SID file headlessly and writes a Standard MIDI File
/// (format 1) transcription of its register activity. All inputs are value
/// types, so this is safe to run on a detached Task alongside live playback.
///
/// - Parameters:
///   - path:        Absolute filesystem path to the .sid file.
///   - song:        1-based subtune index.
///   - durationMs:  How many milliseconds to transcribe (from HVSC Songlengths).
///   - sampleRate:  Render sample rate in Hz (used only to advance emulation).
///   - config:      Emulation settings to apply.
///   - options:     Transcription tunables.
///   - destination: File URL to write (created / overwritten).
public func exportSIDToMIDI(
    path: String,
    song: Int,
    durationMs: Int,
    sampleRate: Int,
    config: EmulationConfig,
    options: MIDIExportOptions = MIDIExportOptions(),
    to destination: URL
) throws {
    guard durationMs > 0 else { throw ExportError.zeroDuration }

    // Dedicated engine — never touches the live playback instance.
    let engine = SIDPlayerEngine()
    let (kernal, basic, chargen) = SIDPlayer.bundleROMData()
    engine.setROMs(kernal: kernal, basic: basic, chargen: chargen)
    engine.applyConfig(config)
    try engine.load(path: path)
    try engine.start(song: song, sampleRate: sampleRate)

    let info = engine.info
    let isNTSC = info?.clock == .ntsc
    let clock: SIDRegisters.Clock = isNTSC ? .ntsc : .pal
    let frameHz = isNTSC ? 60.0 : 50.0
    // Sample registers at the tune's actual play rate so every play-call (and
    // thus every arpeggio step) is captured.
    let playRateHz = frameHz * Double(engine.playSpeedMultiplier())
    let chips = max(1, info?.sidChips ?? 1)
    let voiceCount = chips * 3

    let totalFrames = Int((Double(durationMs) / 1000.0 * playRateHz).rounded())
    guard totalFrames > 0 else { throw ExportError.zeroDuration }

    let tracker = SIDNoteTracker(voiceCount: voiceCount, clock: clock, options: options)

    let bufCap = 4096
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: bufCap)
    defer { scratch.deallocate() }

    // Advance the emulator one play-frame of audio at a time (discarding the
    // PCM), then snapshot the just-written registers. Fractional samples-per-
    // frame are accumulated so timing doesn't drift over a long tune.
    let samplesPerFrame = Double(sampleRate) / playRateHz
    var sampleTarget = 0.0
    var rendered = 0
    var lastFrame = totalFrames

    outer: for f in 0..<totalFrames {
        sampleTarget += samplesPerFrame
        var want = Int(sampleTarget.rounded(.down)) - rendered
        var stopped = false
        while want > 0 {
            let n = min(bufCap, want)
            let got = engine.render(into: scratch, count: n)
            if got <= 0 { stopped = true; break }
            rendered += got
            want -= got
            if got < n { stopped = true; break }
        }

        var voices: [SIDRegisters.Voice] = []
        voices.reserveCapacity(voiceCount)
        for c in 0..<chips {
            let image = engine.readRegisters(sid: c) ?? [UInt8](repeating: 0, count: 32)
            voices.append(contentsOf: SIDRegisters(image: image).voices)
        }
        tracker.step(frame: f, voices: voices)

        if stopped { lastFrame = f + 1; break outer }
    }
    tracker.finish(endFrame: lastFrame)

    let programs = (0..<voiceCount).map { tracker.program(forVoice: $0) }
    let data = buildSMF(notes: tracker.notes, voiceCount: voiceCount,
                        programs: programs, playRateHz: playRateHz)
    try data.write(to: destination, options: .atomic)
}

// MARK: - Standard MIDI File writer

/// Builds a format-1 SMF: a tempo track plus one track per SID voice. Timing is
/// real-time (120 BPM / 480 PPQ → 960 ticks/sec); no musical-bar quantisation is
/// attempted, so playback speed is faithful but bars won't align to a grid.
func buildSMF(notes: [TranscribedNote], voiceCount: Int,
              programs: [UInt8], playRateHz: Double) -> Data {
    let ppq = 480
    let ticksPerSecond = Double(ppq) * 2.0   // 120 BPM
    func tick(_ frame: Int) -> Int {
        playRateHz > 0 ? Int((Double(frame) / playRateHz * ticksPerSecond).rounded()) : 0
    }

    var tracks = Data()
    var trackCount = 0

    // Track 0: tempo map (500000 µs/quarter = 120 BPM).
    tracks += smfTrack(events: [(0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])], name: "Tempo")
    trackCount += 1

    // One track per voice.
    for i in 0..<voiceCount {
        var events: [(Int, [UInt8])] = []
        events.append((0, [0xC0 | UInt8(i & 0x0F), programs[i]]))   // program change
        for n in notes where n.voiceIndex == i {
            let ch = UInt8(n.channel & 0x0F)
            events.append((tick(n.startFrame), [0x90 | ch, UInt8(n.key), UInt8(n.velocity)]))
            events.append((tick(n.endFrame),   [0x80 | ch, UInt8(n.key), 0]))
        }
        tracks += smfTrack(events: events, name: "Voice \(i + 1)")
        trackCount += 1
    }

    var header = Data()
    header += smfFourCC("MThd")
    header += smfBE32(6)
    header += smfBE16(1)                      // format 1
    header += smfBE16(UInt16(trackCount))
    header += smfBE16(UInt16(ppq))            // division: ticks per quarter
    return header + tracks
}

/// Serialises one MTrk chunk. Events are (absoluteTick, statusBytes); they're
/// sorted by tick with note-offs ordered before note-ons at the same tick so a
/// same-key retrigger doesn't get swallowed by a zero-length overlap.
private func smfTrack(events: [(Int, [UInt8])], name: String) -> Data {
    let ordered = events.enumerated().sorted { a, b in
        if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
        let aOff = (a.element.1.first ?? 0) & 0xF0 == 0x80
        let bOff = (b.element.1.first ?? 0) & 0xF0 == 0x80
        if aOff != bOff { return aOff && !bOff }   // note-offs first
        return a.offset < b.offset                 // otherwise stable
    }.map(\.element)

    var body = Data()
    // Track name meta at tick 0.
    let nameBytes = Array(name.utf8)
    body += smfVLQ(0); body += [0xFF, 0x03]; body += smfVLQ(nameBytes.count); body += nameBytes

    var last = 0
    for (tick, bytes) in ordered {
        body += smfVLQ(max(0, tick - last))
        body += bytes
        last = tick
    }
    body += smfVLQ(0); body += [0xFF, 0x2F, 0x00]   // end of track

    var chunk = Data()
    chunk += smfFourCC("MTrk")
    chunk += smfBE32(UInt32(body.count))
    chunk += body
    return chunk
}

/// Variable-length quantity (big-endian, 7 bits/byte, high bit = continuation).
func smfVLQ(_ value: Int) -> [UInt8] {
    var v = UInt32(max(0, value))
    var out = [UInt8(v & 0x7F)]
    v >>= 7
    while v > 0 {
        out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
        v >>= 7
    }
    return out
}

private func smfFourCC(_ s: String) -> Data { Data(s.utf8) }
private func smfBE16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
private func smfBE32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

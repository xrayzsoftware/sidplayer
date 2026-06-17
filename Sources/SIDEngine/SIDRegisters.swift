import Foundation

/// Decoded view of one SID chip's 25 programmed registers ($D400–$D418), built
/// from the 32-byte image `SIDPlayerEngine.readRegisters` returns. A pure value
/// type — no engine access — so it's trivially testable and safe to hand to
/// SwiftUI.
///
/// Note: `getSidStatus` reports the *last values written* to each register, i.e.
/// the programmed waveform / ADSR / filter settings. It does NOT expose the live
/// envelope amplitude (that's internal emulator state), so a UI should present
/// ADSR as the programmed shape, not a moving playhead.
public struct SIDRegisters: Equatable, Sendable {

    /// System clock the oscillator frequency is referenced against. PAL and
    /// NTSC differ by ~4 %, which shifts the decoded pitch by up to ~0.6 of a
    /// semitone, so the right clock matters for an accurate note readout.
    public enum Clock: Sendable {
        case pal, ntsc
        /// C64 CPU / SID master clock in Hz.
        public var cpuHz: Double { self == .ntsc ? 1_022_730 : 985_248 }
    }

    public struct Voice: Equatable, Sendable {
        public let frequency: UInt16    // raw 16-bit frequency register
        public let pulseWidth: UInt16   // 12-bit duty (0…4095)
        public let control: UInt8       // raw control register
        public let attack: UInt8        // 0…15 rate
        public let decay: UInt8         // 0…15 rate
        public let sustain: UInt8       // 0…15 level (not a time)
        public let release: UInt8       // 0…15 rate

        public var gate: Bool     { control & 0x01 != 0 }
        public var sync: Bool     { control & 0x02 != 0 }
        public var ringMod: Bool  { control & 0x04 != 0 }
        public var test: Bool     { control & 0x08 != 0 }
        public var triangle: Bool { control & 0x10 != 0 }
        public var sawtooth: Bool { control & 0x20 != 0 }
        public var pulse: Bool    { control & 0x40 != 0 }
        public var noise: Bool    { control & 0x80 != 0 }

        /// Pulse duty cycle as a percentage (0…100). Only meaningful when the
        /// pulse waveform bit is set.
        public var pulseWidthPercent: Double { Double(pulseWidth) / 4095.0 * 100.0 }

        /// Oscillator output frequency in Hz for the given system clock.
        /// Fout = Freg · Fclk / 2²⁴.
        public func frequencyHz(clock: Clock) -> Double {
            Double(frequency) * clock.cpuHz / 16_777_216.0
        }

        /// Nearest equal-tempered note (A4 = 440 Hz), or nil when the oscillator
        /// is silent (frequency register 0).
        public func note(clock: Clock) -> SIDNote? {
            guard frequency > 0 else { return nil }
            let hz = frequencyHz(clock: clock)
            guard hz > 0 else { return nil }
            let midi = 69.0 + 12.0 * log2(hz / 440.0)
            let nearest = Int(midi.rounded())
            let cents = Int(((midi - Double(nearest)) * 100).rounded())
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            let idx = ((nearest % 12) + 12) % 12
            // MIDI 69 = A4, so octave = floor(n / 12) − 1.
            let octave = Int(floor(Double(nearest) / 12.0)) - 1
            return SIDNote(name: names[idx], octave: octave, cents: cents)
        }
    }

    public let voices: [Voice]      // always 3
    public let cutoff: UInt16       // 11-bit filter cutoff (0…2047)
    public let resonance: UInt8     // 0…15
    public let filterVoice1: Bool
    public let filterVoice2: Bool
    public let filterVoice3: Bool
    public let filterExternal: Bool
    public let lowpass: Bool
    public let bandpass: Bool
    public let highpass: Bool
    public let voice3Off: Bool      // voice 3 disconnected from the audio output
    public let volume: UInt8        // 0…15 master volume

    /// Decodes a register image. Accepts any length ≥ 25 (the 32-byte buffer
    /// `getSidStatus` fills); missing bytes read as 0.
    public init(image regs: [UInt8]) {
        func reg(_ i: Int) -> UInt8 { i < regs.count ? regs[i] : 0 }

        var vs: [Voice] = []
        vs.reserveCapacity(3)
        for v in 0..<3 {
            let b = v * 7
            vs.append(Voice(
                frequency:  UInt16(reg(b)) | (UInt16(reg(b + 1)) << 8),
                pulseWidth: UInt16(reg(b + 2)) | (UInt16(reg(b + 3) & 0x0F) << 8),
                control:    reg(b + 4),
                attack:     reg(b + 5) >> 4,
                decay:      reg(b + 5) & 0x0F,
                sustain:    reg(b + 6) >> 4,
                release:    reg(b + 6) & 0x0F
            ))
        }
        voices = vs

        // $15 holds the low 3 bits of cutoff, $16 the high 8 bits.
        cutoff = (UInt16(reg(0x16)) << 3) | UInt16(reg(0x15) & 0x07)

        let resFilt = reg(0x17)
        resonance      = resFilt >> 4
        filterVoice1   = resFilt & 0x01 != 0
        filterVoice2   = resFilt & 0x02 != 0
        filterVoice3   = resFilt & 0x04 != 0
        filterExternal = resFilt & 0x08 != 0

        let modeVol = reg(0x18)
        volume    = modeVol & 0x0F
        lowpass   = modeVol & 0x10 != 0
        bandpass  = modeVol & 0x20 != 0
        highpass  = modeVol & 0x40 != 0
        voice3Off = modeVol & 0x80 != 0
    }
}

/// An equal-tempered note name with octave and cents deviation.
public struct SIDNote: Equatable, Sendable {
    public let name: String     // "C", "C#", … "B"
    public let octave: Int      // scientific pitch; A4 = 440 Hz
    public let cents: Int       // −50…+50 deviation from equal temperament

    public var display: String { "\(name)\(octave)" }
}

/// Canonical 6581/8580 envelope timings, indexed by the 4-bit rate value, at the
/// datasheet's 1 MHz reference clock. Useful for turning the raw attack/decay/
/// release nibbles into human-readable durations.
public enum SIDEnvelope {
    /// Attack time (ms) to ramp 0 → peak, per rate value 0…15.
    public static let attackMs: [Int] =
        [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]

    /// Decay / release time (ms) — the full-scale fall, per rate value 0…15.
    /// These are 3× the attack values, as the 6581 datasheet specifies.
    public static let decayReleaseMs: [Int] =
        [6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000]

    public static func attack(_ rate: UInt8) -> Int { attackMs[Int(rate) & 0x0F] }
    public static func decay(_ rate: UInt8) -> Int { decayReleaseMs[Int(rate) & 0x0F] }
    public static func release(_ rate: UInt8) -> Int { decayReleaseMs[Int(rate) & 0x0F] }
}

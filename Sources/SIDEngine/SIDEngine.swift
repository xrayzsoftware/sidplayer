import Foundation
import CSIDEngine

public enum SIDClock: Int, Sendable {
    case unknown, pal, ntsc, any
    init(_ raw: CSIDClock) {
        switch raw {
        case .PAL:  self = .pal
        case .NTSC: self = .ntsc
        case .any:  self = .any
        default:    self = .unknown
        }
    }
    public var displayName: String {
        switch self {
        case .pal: return "PAL"
        case .ntsc: return "NTSC"
        case .any: return "ANY"
        case .unknown: return "?"
        }
    }
}

public enum SIDModel: Int, Sendable {
    case unknown, mos6581, mos8580, any
    init(_ raw: CSIDModel) {
        switch raw {
        case .model6581: self = .mos6581
        case .model8580: self = .mos8580
        case .modelAny:  self = .any
        default:         self = .unknown
        }
    }
    public var displayName: String {
        switch self {
        case .mos6581: return "6581"
        case .mos8580: return "8580"
        case .any: return "ANY"
        case .unknown: return "?"
        }
    }
}

public struct EmulationConfig: Sendable, Equatable {
    public enum SIDModelChoice: String, Sendable, CaseIterable {
        case auto = "auto"
        case mos6581 = "6581"
        case mos8580 = "8580"

        public var label: String {
            switch self {
            case .auto:    return "Auto"
            case .mos6581: return "6581"
            case .mos8580: return "8580"
            }
        }
    }

    public enum ClockChoice: String, Sendable, CaseIterable {
        case auto = "auto"
        case pal = "pal"
        case ntsc = "ntsc"

        public var label: String {
            switch self {
            case .auto: return "Auto"
            case .pal:  return "PAL"
            case .ntsc: return "NTSC"
            }
        }
    }

    public enum SamplingMethod: String, Sendable, CaseIterable {
        case interpolate = "interpolate"
        case resample = "resample"

        public var label: String {
            switch self {
            case .interpolate: return "Fast"
            case .resample:    return "Quality"
            }
        }
    }

    public enum EngineChoice: String, Sendable, CaseIterable {
        case residfp = "residfp"
        case sidlite = "sidlite"

        public var label: String {
            switch self {
            case .residfp: return "reSIDfp"
            case .sidlite: return "SIDLite"
            }
        }
    }

    public var sidModel: SIDModelChoice = .auto
    public var clock: ClockChoice = .auto
    public var digiBoost: Bool = false
    public var sampling: SamplingMethod = .interpolate
    /// Emulation core. reSIDfp is the full-quality analog model (and the only
    /// one whose 6581/8580 filter curve is adjustable); SIDLite is lighter.
    public var engine: EngineChoice = .residfp
    /// 6581 / 8580 filter curve, 0…1 (dark → bright). reSIDfp only.
    public var filter6581Curve: Double = 0.5
    public var filter8580Curve: Double = 0.5

    public init() {}
}

public struct TuneInfo: Sendable {
    public let title: String?
    public let author: String?
    public let released: String?
    public let format: String?
    public let md5: String?
    public let songCount: Int
    public let startSong: Int
    public let sidChips: Int
    public let clock: SIDClock
    public let model: SIDModel
}

public final class SIDPlayerEngine {
    private let bridge: CSIDEngine

    public init() {
        self.bridge = CSIDEngine()
    }

    /// Compute the HVSC#68+ MD5 of a SID file without instantiating an engine.
    /// Returns nil if the file isn't a valid SID.
    public static func md5(forFileAt path: String) -> String? {
        CSIDEngine.md5ForFile(atPath: path)
    }

    public func load(path: String) throws {
        try bridge.loadTune(atPath: path)
    }

    public var info: TuneInfo? {
        guard let raw = bridge.tuneInfo() else { return nil }
        return TuneInfo(
            title:     raw.title,
            author:    raw.author,
            released:  raw.released,
            format:    raw.format,
            md5:       raw.md5,
            songCount: raw.songCount,
            startSong: raw.startSong,
            sidChips:  raw.sidChips,
            clock:     SIDClock(raw.clock),
            model:     SIDModel(raw.model)
        )
    }

    public func start(song: Int, sampleRate: Int) throws {
        try bridge.startSong(song, sampleRate: sampleRate)
    }

    public func select(song: Int) throws {
        try bridge.selectSong(song)
    }

    public var currentSong: Int { bridge.currentSong }

    public func nextSong() throws {
        guard let info, currentSong > 0 else { return }
        let next = currentSong >= info.songCount ? 1 : currentSong + 1
        try select(song: next)
    }

    public func previousSong() throws {
        guard let info, currentSong > 0 else { return }
        let prev = currentSong <= 1 ? info.songCount : currentSong - 1
        try select(song: prev)
    }

    /// Renders mono Int16 PCM. Returns frames written.
    public func render(into buffer: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        bridge.renderFrames(buffer, count: count)
    }

    public var currentTime: TimeInterval {
        bridge.currentTime()
    }

    /// Mute/unmute one of the three SID voices (0, 1, 2). Effective immediately.
    public func setVoiceMuted(_ voice: Int, muted: Bool) {
        bridge.setVoiceMuted(voice, muted: muted)
    }

    /// Raw CIA1 Timer A value programmed by the tune (0 if VBI / not set yet).
    public var cia1TimerA: Int { bridge.cia1TimerA() }

    /// Snapshots the last-written register image (32 bytes) of SID chip `sid`
    /// (0, 1, or 2). Returns nil if that chip isn't present. Call from the
    /// producer thread — it reads engine state and must not race `render`.
    public func readRegisters(sid: Int = 0) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 32)
        let ok = buf.withUnsafeMutableBufferPointer { ptr in
            bridge.readRegisters(ptr.baseAddress!, forSID: sid)
        }
        return ok ? buf : nil
    }

    /// Provides C64 system ROMs to the engine. Many RSID tunes call into
    /// KERNAL routines and won't play correctly without these. Pass nil
    /// to clear (uses internal fallback patches; some tunes will still fail).
    public func setROMs(kernal: Data?, basic: Data?, chargen: Data?) {
        bridge.setKernalROM(kernal, basicROM: basic, chargenROM: chargen)
    }

    /// Computes the play-rate multiplier relative to the video frame rate.
    /// VBI-driven tunes return 1; CIA-driven tunes return 2, 4, etc.
    public func playSpeedMultiplier() -> Int {
        let cia = bridge.cia1TimerA()
        guard cia > 0 else { return 1 }
        let info = self.info
        let cpuHz: Double = info?.clock == .ntsc ? 1_022_730 : 985_248
        let frameHz: Double = info?.clock == .ntsc ? 60 : 50
        let playFreq = cpuHz / Double(cia + 1)
        let raw = playFreq / frameHz
        // Snap to the nearest power-of-two-ish that SID composers actually use.
        if raw < 1.5 { return 1 }
        if raw < 3.0 { return 2 }
        if raw < 6.0 { return 4 }
        if raw < 12.0 { return 8 }
        return Int(raw.rounded())
    }

    public func stop() {
        bridge.stop()
    }

    /// Applies emulation settings to the underlying engine. Call before
    /// start(song:sampleRate:) for the settings to take effect.
    public func applyConfig(_ config: EmulationConfig) {
        switch config.sidModel {
        case .auto:
            bridge.forceSidModel = false
        case .mos6581:
            bridge.defaultSidModel = .model6581
            bridge.forceSidModel = true
        case .mos8580:
            bridge.defaultSidModel = .model8580
            bridge.forceSidModel = true
        }

        switch config.clock {
        case .auto:
            bridge.forceC64Model = false
        case .pal:
            bridge.defaultC64Model = .PAL
            bridge.forceC64Model = true
        case .ntsc:
            bridge.defaultC64Model = .NTSC
            bridge.forceC64Model = true
        }

        bridge.digiBoost = config.digiBoost
        bridge.samplingMethod = (config.sampling == .resample)
            ? .resample : .interpolate
        bridge.useReSIDfp = (config.engine == .residfp)
        bridge.filter6581Curve = config.filter6581Curve
        bridge.filter8580Curve = config.filter8580Curve
    }
}

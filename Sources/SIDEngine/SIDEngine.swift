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

    public func stop() {
        bridge.stop()
    }
}

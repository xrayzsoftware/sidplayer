import Foundation

/// Parses PSID v1-v4 and RSID v2-v4 headers without touching libsidplayfp.
/// Spec: https://www.hvsc.c64.org/download/C64Music/DOCUMENTS/SID_file_format.txt
public struct PSIDHeader: Sendable, Equatable {
    public enum Format: String, Sendable { case psid = "PSID", rsid = "RSID" }

    public let format: Format
    public let version: UInt16
    public let dataOffset: UInt16
    public let loadAddress: UInt16
    public let initAddress: UInt16
    public let playAddress: UInt16
    public let songs: UInt16
    public let startSong: UInt16
    public let speed: UInt32
    public let title: String?
    public let author: String?
    public let released: String?

    // v2+ fields. nil for v1 PSIDs.
    public let flags: UInt16?
    public let startPage: UInt8?
    public let pageLength: UInt8?
    public let secondSIDAddress: UInt16?
    public let thirdSIDAddress: UInt16?

    public var clock: SIDClock {
        guard let f = flags else { return .unknown }
        switch (f >> 2) & 0b11 {
        case 0b01: return .pal
        case 0b10: return .ntsc
        case 0b11: return .any
        default:   return .unknown
        }
    }

    public var model: SIDModel {
        guard let f = flags else { return .unknown }
        switch (f >> 4) & 0b11 {
        case 0b01: return .mos6581
        case 0b10: return .mos8580
        case 0b11: return .any
        default:   return .unknown
        }
    }

    public enum ParseError: Error, CustomStringConvertible {
        case fileTooShort(Int)
        case badMagic(String)
        case unsupportedVersion(UInt16)

        public var description: String {
            switch self {
            case .fileTooShort(let n): return "file is \(n) bytes; need at least 0x76"
            case .badMagic(let s):     return "bad magic '\(s)' (expected PSID or RSID)"
            case .unsupportedVersion(let v): return "unsupported PSID version \(v)"
            }
        }
    }

    public init(data: Data) throws {
        guard data.count >= 0x76 else {
            throw ParseError.fileTooShort(data.count)
        }
        let magic = String(data: data[0..<4], encoding: .ascii) ?? ""
        let format: Format
        switch magic {
        case "PSID": format = .psid
        case "RSID": format = .rsid
        default: throw ParseError.badMagic(magic)
        }

        let version    = data.beUInt16(at: 0x04)
        guard (1...4).contains(version) else { throw ParseError.unsupportedVersion(version) }

        let dataOffset = data.beUInt16(at: 0x06)
        let loadAddr   = data.beUInt16(at: 0x08)
        let initAddr   = data.beUInt16(at: 0x0A)
        let playAddr   = data.beUInt16(at: 0x0C)
        let songs      = data.beUInt16(at: 0x0E)
        let startSong  = data.beUInt16(at: 0x10)
        let speed      = data.beUInt32(at: 0x12)
        let title      = data.psidString(at: 0x16)
        let author     = data.psidString(at: 0x36)
        let released   = data.psidString(at: 0x56)

        var flags: UInt16? = nil
        var startPage: UInt8? = nil
        var pageLen: UInt8? = nil
        var sid2: UInt16? = nil
        var sid3: UInt16? = nil

        if version >= 2 && data.count >= 0x7C {
            flags = data.beUInt16(at: 0x76)
            startPage = data[0x78]
            pageLen = data[0x79]
            // 2nd SID base address (LSB) — present in v2 (zero) and used in v3+
            let lsb2 = data[0x7A]
            sid2 = lsb2 == 0 ? nil : 0xD000 | (UInt16(lsb2) << 4)
        }
        if version >= 4 && data.count >= 0x7E {
            let lsb3 = data[0x7B]
            sid3 = lsb3 == 0 ? nil : 0xD000 | (UInt16(lsb3) << 4)
        }

        self.format = format
        self.version = version
        self.dataOffset = dataOffset
        self.loadAddress = loadAddr
        self.initAddress = initAddr
        self.playAddress = playAddr
        self.songs = songs
        self.startSong = startSong
        self.speed = speed
        self.title = title
        self.author = author
        self.released = released
        self.flags = flags
        self.startPage = startPage
        self.pageLength = pageLen
        self.secondSIDAddress = sid2
        self.thirdSIDAddress = sid3
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }
}

private extension Data {
    func beUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
    func beUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) |
        (UInt32(self[offset + 1]) << 16) |
        (UInt32(self[offset + 2]) << 8)  |
         UInt32(self[offset + 3])
    }
    /// PSID strings: 32 bytes ISO-8859-1, null-terminated, padded with 0.
    func psidString(at offset: Int) -> String? {
        let end = offset + 32
        guard end <= count else { return nil }
        let slice = self[offset..<end]
        let firstNull = slice.firstIndex(of: 0) ?? end
        let trimmed = self[offset..<firstNull]
        if trimmed.isEmpty { return nil }
        return String(data: trimmed, encoding: .isoLatin1)
    }
}

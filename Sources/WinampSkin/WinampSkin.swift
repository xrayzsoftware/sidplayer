import Foundation
import CoreGraphics
import ImageIO
import SWCompression

public enum WinampSkinError: Error, LocalizedError, Equatable {
    case notAnArchive
    case missingMainBitmap

    public var errorDescription: String? {
        switch self {
        case .notAnArchive:      return "That file is not a Winamp skin (.wsz is a zip archive)."
        case .missingMainBitmap: return "That archive has no main.bmp, so it is not a classic Winamp skin."
        }
    }
}

/// A classic (Winamp 2.x) skin: the sprite sheets from a `.wsz` archive plus
/// the two text files that colour the playlist and the spectrum analyser.
///
/// A `.wsz` is a plain zip. File names are matched without regard to case or
/// to any folder the author zipped the skin inside — both vary in the wild.
/// Immutable after init, so it is safe to hand between threads.
public final class WinampSkin: @unchecked Sendable {
    public struct RGB: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    public struct PlaylistStyle: Equatable, Sendable {
        public var normal = RGB(0, 255, 0)
        public var current = RGB(255, 255, 255)
        public var normalBackground = RGB(0, 0, 0)
        public var selectedBackground = RGB(0, 0, 198)
        public var fontName = "Arial"
        public init() {}
    }

    /// Sprite sheets keyed by lower-case base name ("main", "cbuttons", ...).
    public let sheets: [String: CGImage]
    public let playlistStyle: PlaylistStyle
    /// The 24 analyser colours: 0 background, 1 dots, 2-17 bar top to bottom,
    /// 18-22 oscilloscope, 23 peak caps.
    public let visColors: [RGB]

    public convenience init(wszData: Data) throws {
        let entries: [ZipEntry]
        do {
            entries = try ZipContainer.open(container: wszData)
        } catch {
            throw WinampSkinError.notAnArchive
        }
        var files: [String: Data] = [:]
        for entry in entries where entry.info.type == .regular {
            guard let data = entry.data else { continue }
            files[entry.info.name] = data
        }
        try self.init(files: files)
    }

    /// `files` maps a path inside the skin to that file's bytes.
    public init(files: [String: Data]) throws {
        var sheets: [String: CGImage] = [:]
        var texts: [String: String] = [:]
        for (path, data) in files {
            let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
            let base = (name as NSString).deletingPathExtension
            switch (name as NSString).pathExtension {
            case "bmp":
                if let image = Self.decode(data) { sheets[base] = image }
            case "txt":
                texts[base] = String(data: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.ASCII.self)
            default:
                break
            }
        }
        guard sheets["main"] != nil else { throw WinampSkinError.missingMainBitmap }
        self.sheets = sheets
        self.playlistStyle = Self.parsePlaylistStyle(texts["pledit"])
        self.visColors = Self.parseVisColors(texts["viscolor"])
    }

    /// The part of sheet `sheet` at `rect` (pixels, origin top left), or nil
    /// if the skin has no such sheet or the sheet is too small — old skins
    /// often leave out the rows that later Winamp versions added.
    public func sprite(_ sheet: String, _ rect: CGRect) -> CGImage? {
        guard let image = sheets[sheet],
              rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height) else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: Parsing

    static let defaultVisColors: [RGB] = [
        RGB(0, 0, 0), RGB(24, 33, 41), RGB(239, 49, 16), RGB(206, 41, 16),
        RGB(214, 90, 0), RGB(214, 102, 0), RGB(214, 115, 0), RGB(198, 123, 8),
        RGB(222, 165, 24), RGB(214, 181, 33), RGB(189, 222, 41), RGB(148, 222, 33),
        RGB(41, 206, 16), RGB(50, 190, 16), RGB(57, 181, 16), RGB(49, 156, 8),
        RGB(41, 148, 0), RGB(24, 132, 8), RGB(255, 255, 255), RGB(214, 214, 222),
        RGB(181, 189, 189), RGB(160, 170, 175), RGB(148, 156, 165), RGB(150, 150, 150),
    ]

    /// viscolor.txt: one "r,g,b" per line, anything after it is a comment.
    /// Missing or short files fall back to Winamp's own colours line by line.
    static func parseVisColors(_ text: String?) -> [RGB] {
        var colors = defaultVisColors
        guard let text else { return colors }
        var index = 0
        for line in text.split(whereSeparator: \.isNewline) where index < colors.count {
            let numbers = line.prefix { $0 != "/" }
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { UInt8($0) }
            guard numbers.count >= 3 else { continue }
            colors[index] = RGB(numbers[0], numbers[1], numbers[2])
            index += 1
        }
        return colors
    }

    /// pledit.txt: an ini section with "Key=#RRGGBB" lines and "Font=Name".
    static func parsePlaylistStyle(_ text: String?) -> PlaylistStyle {
        var style = PlaylistStyle()
        guard let text else { return style }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0].lowercased() {
            case "normal":     if let c = parseHex(value) { style.normal = c }
            case "current":    if let c = parseHex(value) { style.current = c }
            case "normalbg":   if let c = parseHex(value) { style.normalBackground = c }
            case "selectedbg": if let c = parseHex(value) { style.selectedBackground = c }
            case "font":       if !value.isEmpty { style.fontName = value }
            default:           break
            }
        }
        return style
    }

    static func parseHex(_ text: String) -> RGB? {
        let hex = text.drop { $0 == "#" }.prefix(6)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return RGB(UInt8(value >> 16), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    /// Decode a bitmap and redraw it as plain 8-bit sRGB, so every sheet has
    /// the same pixel format whatever bit depth or palette the file used.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

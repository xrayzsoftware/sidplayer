import Foundation
import CoreGraphics

/// The skin's own bitmap font (text.bmp): 5x6 glyphs in three rows of 31.
/// Used for the song title and the two small number fields.
enum SkinText {
    static let glyphWidth = 5
    static let glyphHeight = 6

    /// Row and column of each glyph. Letters have one case only; a character
    /// with no glyph is drawn as a space, which is what Winamp does.
    private static let glyphs: [Character: (row: Int, column: Int)] = {
        var table: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz\"@".enumerated() { table[c] = (0, i) }
        for (i, c) in "0123456789….:()-'!_+\\/[]^&%,=$#".enumerated() { table[c] = (1, i) }
        for (i, c) in "åöä?*".enumerated() { table[c] = (2, i) }
        table[" "] = (0, 30)
        table["<"] = (1, 22); table[">"] = (1, 23)
        table["{"] = (1, 22); table["}"] = (1, 23)
        return table
    }()

    /// Lower-case `text` and strip the accents text.bmp has no glyph for.
    static func normalized(_ text: String) -> [Character] {
        text.lowercased().map { c in
            if glyphs[c] != nil { return c }
            let plain = String(c).folding(options: .diacriticInsensitive, locale: nil)
            if let first = plain.first, plain.count == 1, glyphs[first] != nil { return first }
            return " "
        }
    }

    static func draw(_ characters: some Sequence<Character>, skin: WinampSkin, on canvas: SkinCanvas, x: Int, y: Int) {
        var x = x
        for c in characters {
            let glyph = glyphs[c] ?? (0, 30)
            let source = CGRect(x: glyph.column * glyphWidth, y: glyph.row * glyphHeight,
                                width: glyphWidth, height: glyphHeight)
            canvas.draw(skin.sprite("text", source), x: x, y: y)
            x += glyphWidth
        }
    }
}

import Foundation
import CoreGraphics

/// Everything the main window shows, as plain values. Two equal models draw
/// the same picture, so the caller can skip a redraw when nothing changed.
public struct MainWindowModel: Equatable, Sendable {
    public enum Status: Sendable { case playing, paused, stopped }

    public enum Control: Hashable, Sendable {
        case previous, play, pause, stop, next, eject
        case shuffle, repeatMode, equalizer, playlist
        case options, minimize, shade, close
        case volume, time
    }

    /// True while the window is the key window (lit title bar).
    public var isActive = true
    public var status: Status = .stopped
    /// Seconds for the big digits; nil hides them (also used for the blink
    /// while paused). `timeIsNegative` adds the minus sign of "time left".
    public var timeSeconds: Int?
    public var timeIsNegative = false
    public var title = ""
    /// How many characters the title has scrolled by; ignored when it fits.
    public var marqueeOffset = 0
    /// The two small number fields. Winamp shows bit rate and sample rate;
    /// the caller decides what a SID tune puts there.
    public var kbps = ""
    public var khz = ""
    public var volume = 0.8
    /// 0...1 through the tune, or nil when its length is unknown.
    public var progress: Double?
    public var shuffle = false
    public var repeats = false
    public var playlistOpen = false
    public var equalizerOpen = false
    /// Window shade: the window rolled up into its 14-pixel title bar.
    public var shaded = false
    /// The control the mouse is holding down, drawn pushed in.
    public var pressed: Control?
    /// Analyser bar heights and peak caps, 0...1, `MainWindow.barCount` each.
    public var bars: [Float] = []
    public var peaks: [Float] = []

    public init() {}
}

/// Classic main window: where each control sits and how the window is drawn.
/// All coordinates are skin pixels in the 275x116 window.
public enum MainWindow {
    public static let width = 275
    public static let height = 116
    public static let shadeHeight = 14
    public static let barCount = 19
    /// Characters of title that fit in the 154-pixel title field.
    public static let titleColumns = 31
    static let titleSeparator = "  ***  "

    typealias Control = MainWindowModel.Control

    static let controlRects: [(Control, CGRect)] = [
        (.options,    CGRect(x: 6,   y: 3,  width: 9,  height: 9)),
        (.minimize,   CGRect(x: 244, y: 3,  width: 9,  height: 9)),
        (.shade,      CGRect(x: 254, y: 3,  width: 9,  height: 9)),
        (.close,      CGRect(x: 264, y: 3,  width: 9,  height: 9)),
        (.time,       CGRect(x: 39,  y: 26, width: 59, height: 13)),
        (.volume,     CGRect(x: 107, y: 57, width: 68, height: 13)),
        (.equalizer,  CGRect(x: 219, y: 58, width: 23, height: 12)),
        (.playlist,   CGRect(x: 242, y: 58, width: 23, height: 12)),
        (.previous,   CGRect(x: 16,  y: 88, width: 23, height: 18)),
        (.play,       CGRect(x: 39,  y: 88, width: 23, height: 18)),
        (.pause,      CGRect(x: 62,  y: 88, width: 23, height: 18)),
        (.stop,       CGRect(x: 85,  y: 88, width: 23, height: 18)),
        (.next,       CGRect(x: 108, y: 88, width: 22, height: 18)),
        (.eject,      CGRect(x: 136, y: 89, width: 22, height: 16)),
        (.shuffle,    CGRect(x: 164, y: 89, width: 46, height: 15)),
        (.repeatMode, CGRect(x: 210, y: 89, width: 28, height: 15)),
    ]

    /// In shade mode the title bar carries a small transport and the time.
    /// Those buttons are part of the bar's picture; only where they are
    /// matters.
    static let shadeControlRects: [(Control, CGRect)] = [
        (.options,  CGRect(x: 6,   y: 3, width: 9,  height: 9)),
        (.minimize, CGRect(x: 244, y: 3, width: 9,  height: 9)),
        (.shade,    CGRect(x: 254, y: 3, width: 9,  height: 9)),
        (.close,    CGRect(x: 264, y: 3, width: 9,  height: 9)),
        (.time,     CGRect(x: 127, y: 4, width: 31, height: 6)),
        (.previous, CGRect(x: 169, y: 2, width: 7,  height: 10)),
        (.play,     CGRect(x: 176, y: 2, width: 10, height: 10)),
        (.pause,    CGRect(x: 186, y: 2, width: 9,  height: 10)),
        (.stop,     CGRect(x: 195, y: 2, width: 9,  height: 10)),
        (.next,     CGRect(x: 204, y: 2, width: 10, height: 10)),
        (.eject,    CGRect(x: 215, y: 2, width: 10, height: 10)),
    ]

    /// The control under a point, if any.
    public static func control(at point: CGPoint, shaded: Bool = false) -> MainWindowModel.Control? {
        (shaded ? shadeControlRects : controlRects).first { $0.1.contains(point) }?.0
    }

    /// True on the title bar outside its buttons: the strip that drags the window.
    public static func isDragStrip(_ point: CGPoint, shaded: Bool = false) -> Bool {
        point.y >= 0 && point.y < 14 && control(at: point, shaded: shaded) == nil
    }

    /// The volume a press at skin x asks for. The thumb is 14 wide and
    /// travels 51 pixels, so the middle of the thumb follows the mouse.
    public static func volume(atX x: CGFloat) -> Double {
        Double(min(1, max(0, (x - 107 - 7) / 51)))
    }

    /// What the title field shows: the title itself when it fits, otherwise
    /// a window onto the title followed by a separator, going round forever.
    static func titleWindow(_ title: String, offset: Int) -> [Character] {
        let text = SkinText.normalized(title)
        guard text.count > titleColumns else { return text }
        let loop = text + Array(titleSeparator)
        let start = ((offset % loop.count) + loop.count) % loop.count
        return (0..<titleColumns).map { loop[(start + $0) % loop.count] }
    }

    /// Number of scroll steps before a title repeats (1 when it does not scroll).
    public static func marqueeLength(_ title: String) -> Int {
        let count = SkinText.normalized(title).count
        return count > titleColumns ? count + titleSeparator.count : 1
    }

    public static func render(_ model: MainWindowModel, skin: WinampSkin, scale: Int) -> CGImage? {
        if model.shaded { return renderShade(model, skin: skin, scale: scale) }
        guard let canvas = SkinCanvas(width: width, height: height, scale: scale) else { return nil }
        func sprite(_ sheet: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
            skin.sprite(sheet, CGRect(x: x, y: y, width: w, height: h))
        }
        let pressed = model.pressed
        let stopped = model.status == .stopped

        canvas.draw(sprite("main", 0, 0, width, height), x: 0, y: 0)

        // Title bar. Its buttons are part of the bar's own picture; only the
        // pushed-in versions are separate sprites.
        canvas.draw(sprite("titlebar", 27, model.isActive ? 0 : 15, 275, 14), x: 0, y: 0)
        switch pressed {
        case .options:  canvas.draw(sprite("titlebar", 0, 9, 9, 9), x: 6, y: 3)
        case .minimize: canvas.draw(sprite("titlebar", 9, 9, 9, 9), x: 244, y: 3)
        case .shade:    canvas.draw(sprite("titlebar", 9, 18, 9, 9), x: 254, y: 3)
        case .close:    canvas.draw(sprite("titlebar", 18, 9, 9, 9), x: 264, y: 3)
        default:        break
        }
        canvas.draw(sprite("titlebar", 304, 0, 8, 43), x: 10, y: 22)

        // Play state lamp, and the little "working" light beside it.
        let lampX: Int
        switch model.status {
        case .playing: lampX = 0
        case .paused:  lampX = 9
        case .stopped: lampX = 18
        }
        canvas.draw(sprite("playpaus", lampX, 0, 9, 9), x: 26, y: 28)
        canvas.draw(sprite("playpaus", model.status == .playing ? 39 : 36, 0, 3, 9), x: 24, y: 28)

        if let seconds = model.timeSeconds {
            drawTime(seconds, negative: model.timeIsNegative, skin: skin, on: canvas)
        }

        if !stopped {
            drawAnalyser(bars: model.bars, peaks: model.peaks, skin: skin, on: canvas)
        }

        canvas.clipped(x: 111, y: 27, w: 154, h: SkinText.glyphHeight) {
            SkinText.draw(titleWindow(model.title, offset: model.marqueeOffset),
                          skin: skin, on: canvas, x: 111, y: 27)
        }
        if !stopped {
            SkinText.draw(SkinText.normalized(String(model.kbps.suffix(3))), skin: skin, on: canvas, x: 111, y: 43)
            SkinText.draw(SkinText.normalized(String(model.khz.suffix(2))), skin: skin, on: canvas, x: 156, y: 43)
        }

        // A SID is one channel: "mono" lights while a tune is loaded.
        canvas.draw(sprite("monoster", 29, stopped ? 12 : 0, 27, 12), x: 212, y: 41)
        canvas.draw(sprite("monoster", 0, 12, 29, 12), x: 239, y: 41)

        // Volume: 28 pictures of the groove filling up, then the thumb.
        let volume = min(1, max(0, model.volume))
        canvas.draw(sprite("volume", 0, Int((volume * 27).rounded()) * 15, 68, 13), x: 107, y: 57)
        canvas.draw(sprite("volume", pressed == .volume ? 0 : 15, 422, 14, 11),
                    x: 107 + Int((volume * 51).rounded()), y: 58)

        // Balance is fixed at centre. Skins without balance.bmp reuse volume.bmp.
        let balanceSheet = skin.sheets["balance"] != nil ? "balance" : "volume"
        canvas.draw(sprite(balanceSheet, 9, 0, 38, 13), x: 177, y: 57)
        canvas.draw(sprite(balanceSheet, 15, 422, 14, 11), x: 177 + 12, y: 58)

        canvas.draw(sprite("shufrep", pressed == .equalizer ? 46 : 0, model.equalizerOpen ? 73 : 61, 23, 12),
                    x: 219, y: 58)
        canvas.draw(sprite("shufrep", pressed == .playlist ? 69 : 23, model.playlistOpen ? 73 : 61, 23, 12),
                    x: 242, y: 58)

        // Song position: shows progress only (a SID tune cannot be seeked).
        canvas.draw(sprite("posbar", 0, 0, 248, 10), x: 16, y: 72)
        if !stopped, let progress = model.progress {
            let travel = Double(248 - 29)
            canvas.draw(sprite("posbar", 248, 0, 29, 10),
                        x: 16 + Int((min(1, max(0, progress)) * travel).rounded()), y: 72)
        }

        let transport: [(Control, Int, Int, Int)] = [
            (.previous, 0, 16, 23), (.play, 23, 39, 23), (.pause, 46, 62, 23),
            (.stop, 69, 85, 23), (.next, 92, 108, 22),
        ]
        for (control, sourceX, x, w) in transport {
            canvas.draw(sprite("cbuttons", sourceX, pressed == control ? 18 : 0, w, 18), x: x, y: 88)
        }
        canvas.draw(sprite("cbuttons", 114, pressed == .eject ? 16 : 0, 22, 16), x: 136, y: 89)

        // Shuffle and repeat: off / off pushed / on / on pushed, 15 rows apart.
        let shuffleRow = (model.shuffle ? 30 : 0) + (pressed == .shuffle ? 15 : 0)
        canvas.draw(sprite("shufrep", 28, shuffleRow, 47, 15), x: 164, y: 89)
        let repeatRow = (model.repeats ? 30 : 0) + (pressed == .repeatMode ? 15 : 0)
        canvas.draw(sprite("shufrep", 0, repeatRow, 28, 15), x: 210, y: 89)

        return canvas.makeImage()
    }

    /// The window rolled up: a 14-pixel bar with the time in the small font
    /// and a 17-pixel position strip. Skins without the shade rows in
    /// titlebar.bmp fall back to the ordinary title bar.
    private static func renderShade(_ model: MainWindowModel, skin: WinampSkin, scale: Int) -> CGImage? {
        guard let canvas = SkinCanvas(width: width, height: shadeHeight, scale: scale) else { return nil }
        func sprite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
            skin.sprite("titlebar", CGRect(x: x, y: y, width: w, height: h))
        }
        let bar = sprite(27, model.isActive ? 29 : 42, 275, 14)
        guard bar != nil else {
            canvas.draw(sprite(27, model.isActive ? 0 : 15, 275, 14), x: 0, y: 0)
            return canvas.makeImage()
        }
        canvas.draw(bar, x: 0, y: 0)
        switch model.pressed {
        case .options:  canvas.draw(sprite(0, 9, 9, 9), x: 6, y: 3)
        case .minimize: canvas.draw(sprite(9, 9, 9, 9), x: 244, y: 3)
        case .shade:    canvas.draw(sprite(9, 27, 9, 9), x: 254, y: 3)
        case .close:    canvas.draw(sprite(18, 9, 9, 9), x: 264, y: 3)
        default:        break
        }

        // Sign, two minute digits, two second digits; the colon is part of
        // the bar. Blank glyphs first so an old time is wiped.
        var characters: [Character] = [" ", " ", " ", " ", " "]
        if let seconds = model.timeSeconds {
            let total = min(abs(seconds), 99 * 60 + 59)
            characters = Array(String(format: "%@%02d%02d", model.timeIsNegative ? "-" : " ", total / 60, total % 60))
        }
        for (character, x) in zip(characters, [128, 134, 139, 147, 152]) {
            SkinText.draw([character], skin: skin, on: canvas, x: x, y: 4)
        }

        if model.status != .stopped, let progress = model.progress {
            let progress = min(1, max(0, progress))
            canvas.draw(sprite(0, 36, 17, 7), x: 226, y: 4)
            // Three thumb pictures: one each for the left, middle and right third.
            let thumbX = progress < 1.0 / 3 ? 17 : (progress < 2.0 / 3 ? 20 : 23)
            canvas.draw(sprite(thumbX, 36, 3, 7), x: 226 + Int((progress * 14).rounded()), y: 4)
        }
        return canvas.makeImage()
    }

    /// The big mm:ss digits. nums_ex.bmp (when the skin has it) carries a
    /// full-height minus sign; plain numbers.bmp only has a 5x1 dash.
    private static func drawTime(_ seconds: Int, negative: Bool, skin: WinampSkin, on canvas: SkinCanvas) {
        let extended = skin.sheets["nums_ex"] != nil
        let sheet = extended ? "nums_ex" : "numbers"
        let total = min(abs(seconds), 99 * 60 + 59)
        let digits = [total / 600, (total / 60) % 10, (total % 60) / 10, total % 10]
        for (digit, x) in zip(digits, [48, 60, 78, 90]) {
            canvas.draw(skin.sprite(sheet, CGRect(x: digit * 9, y: 0, width: 9, height: 13)), x: x, y: 26)
        }
        if extended {
            canvas.draw(skin.sprite(sheet, CGRect(x: negative ? 99 : 90, y: 0, width: 9, height: 13)), x: 38, y: 26)
        } else {
            canvas.draw(skin.sprite(sheet, CGRect(x: negative ? 20 : 9, y: 6, width: 5, height: 1)), x: 38, y: 32)
        }
    }

    /// The 76x16 spectrum analyser: 19 bars three pixels wide. A bar's colour
    /// depends on the row, not on its height — row 0 (top) is colour 2.
    private static func drawAnalyser(bars: [Float], peaks: [Float], skin: WinampSkin, on canvas: SkinCanvas) {
        let left = 24, top = 43, rows = 16
        let colors = skin.visColors
        canvas.fill(colors[0], x: left, y: top, w: 76, h: rows)
        for y in stride(from: 0, to: rows, by: 2) {
            for x in stride(from: 0, to: 76, by: 2) {
                canvas.fill(colors[1], x: left + x, y: top + y, w: 1, h: 1)
            }
        }
        for bar in 0..<barCount {
            let level = bar < bars.count ? min(1, max(0, bars[bar])) : 0
            let lit = Int((level * Float(rows)).rounded())
            let x = left + bar * 4
            for row in (rows - lit)..<rows {
                canvas.fill(colors[2 + row], x: x, y: top + row, w: 3, h: 1)
            }
            let peak = bar < peaks.count ? min(1, max(0, peaks[bar])) : 0
            let peakRow = rows - Int((peak * Float(rows)).rounded())
            if peakRow < rows - lit {
                canvas.fill(colors[23], x: x, y: top + peakRow, w: 3, h: 1)
            }
        }
    }
}

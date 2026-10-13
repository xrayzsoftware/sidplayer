import Foundation
import CoreGraphics
import CoreText

/// What the playlist pane shows. The caller passes only the rows on screen,
/// so a 60,000-tune list costs the same to draw as a short one.
public struct PlaylistModel: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var text: String
        public var duration: String
        public var isCurrent: Bool
        public var isSelected: Bool
        public init(text: String, duration: String, isCurrent: Bool, isSelected: Bool) {
            self.text = text; self.duration = duration
            self.isCurrent = isCurrent; self.isSelected = isSelected
        }
    }

    public var isActive = true
    /// Height of the track area in 29-pixel steps (the skin's side tile).
    public var units = 6
    public var entries: [Entry] = []
    /// 0 at the top of the list, 1 at the bottom.
    public var scrollFraction = 0.0
    public var scrollPressed = false

    public init() {}
}

/// Classic playlist window, drawn from pledit.bmp and coloured by pledit.txt.
/// Fixed at the main window's width; the height grows in 29-pixel steps.
public enum PlaylistWindow {
    public static let width = 275
    static let rowHeight = 13
    static let listLeft = 12, listTop = 20
    static let listWidth = width - 12 - 20
    static let handleHeight = 18

    public static func height(units: Int) -> Int { 20 + 38 + 29 * max(1, units) }
    public static func visibleRows(units: Int) -> Int { 29 * max(1, units) / rowHeight }

    /// Index (within the visible rows) of the row under a point.
    public static func row(at point: CGPoint, units: Int) -> Int? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= listLeft, x < listLeft + listWidth, y >= listTop else { return nil }
        let row = (y - listTop) / rowHeight
        return row < visibleRows(units: units) ? row : nil
    }

    public static func isScrollBar(_ point: CGPoint, units: Int) -> Bool {
        point.x >= CGFloat(width - 15) && point.x < CGFloat(width - 6)
            && point.y >= CGFloat(listTop) && point.y < CGFloat(listTop + 29 * max(1, units))
    }

    /// The scroll position a press at skin y asks for (handle centred on it).
    public static func scrollFraction(atY y: CGFloat, units: Int) -> Double {
        let travel = CGFloat(29 * max(1, units) - handleHeight)
        guard travel > 0 else { return 0 }
        return Double(min(1, max(0, (y - CGFloat(listTop) - CGFloat(handleHeight) / 2) / travel)))
    }

    public static func isDragStrip(_ point: CGPoint) -> Bool { point.y >= 0 && point.y < 20 }

    public static func render(_ model: PlaylistModel, skin: WinampSkin, scale: Int) -> CGImage? {
        let units = max(1, model.units)
        let height = height(units: units)
        guard let canvas = SkinCanvas(width: width, height: height, scale: scale) else { return nil }
        func sprite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
            skin.sprite("pledit", CGRect(x: x, y: y, width: w, height: h))
        }
        let style = skin.playlistStyle
        canvas.fill(style.normalBackground, x: 0, y: 0, w: width, h: height)

        // Frame: a tiled top with the title piece centred, the two side
        // strips, and a bottom made of exactly two corner pieces.
        let topRow = model.isActive ? 0 : 21
        for x in stride(from: 25, to: width - 25, by: 25) {
            canvas.draw(sprite(127, topRow, 25, 20), x: x, y: 0)
        }
        canvas.draw(sprite(26, topRow, 100, 20), x: (width - 100) / 2, y: 0)
        canvas.draw(sprite(0, topRow, 25, 20), x: 0, y: 0)
        canvas.draw(sprite(153, topRow, 25, 20), x: width - 25, y: 0)
        for unit in 0..<units {
            canvas.draw(sprite(0, 42, 12, 29), x: 0, y: listTop + unit * 29)
            canvas.draw(sprite(31, 42, 20, 29), x: width - 20, y: listTop + unit * 29)
        }
        canvas.draw(sprite(0, 72, 125, 38), x: 0, y: height - 38)
        canvas.draw(sprite(126, 72, 150, 38), x: width - 150, y: height - 38)

        let listHeight = 29 * units
        let font = CTFontCreateWithName(style.fontName as CFString, 10, nil)
        canvas.clipped(x: listLeft, y: listTop, w: listWidth, h: listHeight) {
            for (index, entry) in model.entries.prefix(visibleRows(units: units)).enumerated() {
                let top = listTop + index * rowHeight
                if entry.isSelected {
                    canvas.fill(style.selectedBackground, x: listLeft, y: top, w: listWidth, h: rowHeight)
                }
                let color = entry.isCurrent ? style.current : style.normal
                let durationWidth = drawText(entry.duration, font: font, color: color, on: canvas,
                                             rightEdge: listLeft + listWidth - 3, top: top)
                drawText(entry.text, font: font, color: color, on: canvas,
                         left: listLeft + 2, top: top,
                         maxWidth: CGFloat(listWidth - 5) - durationWidth - 6)
            }
        }

        let travel = listHeight - handleHeight
        let handleY = listTop + Int((min(1, max(0, model.scrollFraction)) * Double(travel)).rounded())
        canvas.draw(sprite(model.scrollPressed ? 61 : 52, 53, 8, 18), x: width - 15, y: handleY)

        return canvas.makeImage()
    }

    // MARK: Text

    private static func line(_ text: String, font: CTFont, color: WinampSkin.RGB) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    /// Draws one line of row text, cut short with an ellipsis if it is too long.
    private static func drawText(_ text: String, font: CTFont, color: WinampSkin.RGB, on canvas: SkinCanvas,
                                 left: Int, top: Int, maxWidth: CGFloat) {
        guard maxWidth > 0 else { return }
        var drawn = line(text, font: font, color: color)
        if CTLineGetTypographicBounds(drawn, nil, nil, nil) > Double(maxWidth) {
            let ellipsis = line("\u{2026}", font: font, color: color)
            drawn = CTLineCreateTruncatedLine(drawn, Double(maxWidth), .end, ellipsis) ?? drawn
        }
        draw(drawn, on: canvas, x: CGFloat(left), top: top)
    }

    /// Draws text ending at `rightEdge`; returns its width.
    @discardableResult
    private static func drawText(_ text: String, font: CTFont, color: WinampSkin.RGB, on canvas: SkinCanvas,
                                 rightEdge: Int, top: Int) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let drawn = line(text, font: font, color: color)
        let width = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        draw(drawn, on: canvas, x: CGFloat(rightEdge) - width, top: top)
        return width
    }

    /// Text is the one thing drawn smooth: at double size it stays sharp
    /// instead of turning into doubled pixels, which is what makes it readable.
    private static func draw(_ line: CTLine, on canvas: SkinCanvas, x: CGFloat, top: Int) {
        let context = canvas.context
        context.saveGState()
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: x, y: CGFloat(canvas.height - top - 10))
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

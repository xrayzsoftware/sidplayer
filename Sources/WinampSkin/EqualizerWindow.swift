import Foundation
import CoreGraphics

/// What the equaliser window shows. Slider values run 0...1 from the bottom
/// of the groove to the top; 0.5 is the centre line (no change).
public struct EqualizerModel: Equatable, Sendable {
    public enum Control: Hashable, Sendable {
        case on, auto, presets, close
        /// 0 is the preamp, 1...10 the bands from 60 Hz to 16 kHz.
        case slider(Int)
    }

    public var isActive = true
    public var enabled = false
    public var preamp = 0.5
    public var bands = [Double](repeating: 0.5, count: EqualizerWindow.bandCount)
    public var pressed: Control?

    public init() {}
}

/// Classic equaliser window, drawn from eqmain.bmp: preamp, ten bands, the
/// little response curve, and the ON and PRESETS buttons.
public enum EqualizerWindow {
    public static let width = 275
    public static let height = 116
    public static let bandCount = 10

    typealias Control = EqualizerModel.Control

    private static let sliderTop = 38
    private static let sliderHeight = 63
    private static let thumbHeight = 11
    /// The thumb's top moves through this many pixels.
    private static let thumbTravel = 51

    static func sliderLeft(_ index: Int) -> Int { index == 0 ? 21 : 78 + (index - 1) * 18 }

    private static let buttonRects: [(Control, CGRect)] = [
        (.close,   CGRect(x: 264, y: 3,  width: 9,  height: 9)),
        (.on,      CGRect(x: 14,  y: 18, width: 26, height: 12)),
        (.auto,    CGRect(x: 40,  y: 18, width: 32, height: 12)),
        (.presets, CGRect(x: 217, y: 18, width: 44, height: 12)),
    ]

    public static func control(at point: CGPoint) -> EqualizerModel.Control? {
        if let button = buttonRects.first(where: { $0.1.contains(point) }) { return button.0 }
        for index in 0...bandCount {
            let rect = CGRect(x: sliderLeft(index), y: sliderTop, width: 14, height: sliderHeight)
            if rect.contains(point) { return .slider(index) }
        }
        return nil
    }

    public static func isDragStrip(_ point: CGPoint) -> Bool {
        point.y >= 0 && point.y < 14 && control(at: point) == nil
    }

    /// The slider value a press at skin y asks for (thumb centred on the mouse).
    public static func sliderValue(atY y: CGFloat) -> Double {
        let top = y - CGFloat(sliderTop) - CGFloat(thumbHeight) / 2
        return Double(1 - min(1, max(0, top / CGFloat(thumbTravel))))
    }

    public static func render(_ model: EqualizerModel, skin: WinampSkin, scale: Int) -> CGImage? {
        guard let canvas = SkinCanvas(width: width, height: height, scale: scale) else { return nil }
        func sprite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGImage? {
            skin.sprite("eqmain", CGRect(x: x, y: y, width: w, height: h))
        }
        let pressed = model.pressed

        canvas.draw(sprite(0, 0, width, height), x: 0, y: 0)
        canvas.draw(sprite(0, model.isActive ? 134 : 149, 275, 14), x: 0, y: 0)
        if pressed == .close { canvas.draw(sprite(0, 125, 9, 9), x: 264, y: 3) }

        // ON has four pictures (off / on, each plain or pushed); AUTO is
        // never on here, so only its two "off" pictures are used.
        let onX = model.enabled ? (pressed == .on ? 187 : 69) : (pressed == .on ? 128 : 10)
        canvas.draw(sprite(onX, 119, 26, 12), x: 14, y: 18)
        canvas.draw(sprite(pressed == .auto ? 154 : 36, 119, 32, 12), x: 40, y: 18)
        canvas.draw(sprite(224, pressed == .presets ? 176 : 164, 44, 12), x: 217, y: 18)

        drawGraph(model, skin: skin, on: canvas)

        // Each slider's groove is one of 28 pictures (two rows of 14) that
        // change colour as the thumb rises; the thumb is drawn on top.
        let values = [model.preamp] + model.bands
        for (index, value) in values.prefix(bandCount + 1).enumerated() {
            let value = min(1, max(0, value))
            let picture = Int((value * 27).rounded())
            let x = sliderLeft(index)
            canvas.draw(sprite(13 + (picture % 14) * 15, 164 + (picture / 14) * 65, 14, sliderHeight),
                        x: x, y: sliderTop)
            canvas.draw(sprite(0, pressed == .slider(index) ? 176 : 164, 11, thumbHeight),
                        x: x + 1, y: sliderTop + Int(((1 - value) * Double(thumbTravel)).rounded()))
        }
        return canvas.makeImage()
    }

    /// The 113x19 response curve: a smooth line through the ten band values,
    /// coloured by height from the skin's one-pixel colour strip, with the
    /// preamp shown as a horizontal line.
    private static func drawGraph(_ model: EqualizerModel, skin: WinampSkin, on canvas: SkinCanvas) {
        let left = 86, top = 17, rows = 19
        canvas.draw(skin.sprite("eqmain", CGRect(x: 0, y: 294, width: 113, height: rows)), x: left, y: top)
        let preampRow = Int(((1 - min(1, max(0, model.preamp))) * Double(rows - 1)).rounded())
        canvas.draw(skin.sprite("eqmain", CGRect(x: 0, y: 314, width: 113, height: 1)), x: left, y: top + preampRow)

        guard model.bands.count == bandCount,
              let colors = skin.sprite("eqmain", CGRect(x: 115, y: 294, width: 1, height: rows)) else { return }
        let points = model.bands.map { (1 - min(1, max(0, $0))) * Double(rows - 1) }
        var lastRow: Int?
        // Bands sit 12 pixels apart; the curve starts 2 pixels in.
        for x in 0...(bandCount - 1) * 12 {
            let row = min(rows - 1, max(0, Int(curve(points, at: Double(x) / 12).rounded())))
            let from = min(row, lastRow ?? row)
            // The strip holds one colour per row: draw it in this column,
            // cut down to the rows the line crosses here.
            canvas.clipped(x: left + 2 + x, y: top + from, w: 1, h: abs(row - (lastRow ?? row)) + 1) {
                canvas.draw(colors, x: left + 2 + x, y: top)
            }
            lastRow = row
        }
    }

    /// Catmull-Rom curve through evenly spaced points; `position` is in
    /// units of one point spacing.
    static func curve(_ points: [Double], at position: Double) -> Double {
        let index = min(points.count - 2, max(0, Int(position)))
        let t = position - Double(index)
        let p0 = points[max(0, index - 1)], p1 = points[index]
        let p2 = points[index + 1], p3 = points[min(points.count - 1, index + 2)]
        return 0.5 * ((2 * p1) + (p2 - p0) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
            + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
    }
}

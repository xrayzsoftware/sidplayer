import Foundation
import CoreGraphics

/// A bitmap the size of one skin window, addressed in skin pixels with the
/// origin at the top left (the way every skin coordinate is written), drawn
/// `scale` device pixels per skin pixel with no smoothing.
struct SkinCanvas {
    let context: CGContext
    let width: Int
    let height: Int

    init?(width: Int, height: Int, scale: Int) {
        guard width > 0, height > 0, scale > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width * scale, height: height * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        self.context = context
        self.width = width
        self.height = height
    }

    /// Core Graphics counts y from the bottom; skins count from the top.
    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: x, y: height - y - h, width: w, height: h)
    }

    func draw(_ image: CGImage?, x: Int, y: Int) {
        guard let image else { return }
        context.draw(image, in: rect(x, y, image.width, image.height))
    }

    func fill(_ color: WinampSkin.RGB, x: Int, y: Int, w: Int, h: Int) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(color.cgColor)
        context.fill(rect(x, y, w, h))
    }

    /// Run `body` with drawing limited to one rectangle.
    func clipped(x: Int, y: Int, w: Int, h: Int, _ body: () -> Void) {
        context.saveGState()
        context.clip(to: rect(x, y, w, h))
        body()
        context.restoreGState()
    }

    func makeImage() -> CGImage? { context.makeImage() }
}

extension WinampSkin.RGB {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

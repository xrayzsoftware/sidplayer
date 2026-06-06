import SwiftUI
import AppKit
import SIDEngine

/// Phosphor-burn oscilloscope. Unlike `VectorscopeView` — which overlays a
/// fixed number of decaying *copies* of the trace — this renders the full-mix
/// waveform into a single bitmap that persists across frames: every frame fades
/// the whole buffer a little toward the screen colour, then *adds* the new beam
/// on top. Because the beam is composited additively, places where it lingers
/// or repeats build up to a hot white core (a real CRT "burn"), while moving
/// sections leave a glowing afterimage that decays smoothly.
///
/// SwiftUI's `Canvas` hands back a freshly-cleared context every frame and
/// can't persist pixels, so the accumulation buffer lives in a reference-typed
/// state object that owns a `CGContext` for the life of the view — mirroring
/// the `PhosphorHistory` / `PeakMeterState` pattern of the other visualizers.

private let kPBSampleCount = 1024
private let kPBGain: CGFloat = 2.0

/// Per-frame fade applied to the whole buffer (normal blend toward the screen
/// colour). 0.12 ≈ a ~130 ms 1/e tail / ~500 ms full afterglow at 60 fps — the
/// main knob for how long the burn lingers (sensible range 0.10…0.18).
private let kPBFadeAlpha: CGFloat = 0.12

/// Beam strokes, widths in points (scaled to pixels at draw time): a wide,
/// faint glow under a thin, brighter core.
private let kPBGlowWidthPt: CGFloat = 3.5
private let kPBCoreWidthPt: CGFloat = 1.2
private let kPBGlowAlpha: CGFloat = 0.20
private let kPBCoreAlpha: CGFloat = 0.55
/// How far the core colour is pushed toward white (0 = pure `theme.waveform`,
/// relying only on additive saturation; 1 = white).
private let kPBCoreWhiteMix: CGFloat = 0.35

private typealias PBColor = (r: CGFloat, g: CGFloat, b: CGFloat)

/// Owns the persistent accumulation bitmap. Only ever touched inside the Canvas
/// closure (main thread); nothing escapes to another thread.
private final class PhosphorBuffer {
    private var cg: CGContext?
    private(set) var pxW = 0
    private(set) var pxH = 0

    /// (Re)creates the bitmap when the pixel size changes, clearing it so a
    /// resize / display-scale change doesn't surface stale pixels.
    func ensure(pxW: Int, pxH: Int) {
        guard pxW >= 1, pxH >= 1 else { return }
        if cg != nil, pxW == self.pxW, pxH == self.pxH { return }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
        ) else { return }
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        cg = ctx
        self.pxW = pxW
        self.pxH = pxH
    }

    /// Fades the previous frame, then composites the new beam additively.
    /// `samples` is the latest mono snapshot in [-1, 1]; colours are sRGB
    /// channels pulled from the active theme this frame.
    func step(samples: [Float], scale: CGFloat, bg: PBColor, glow: PBColor, core: PBColor) {
        guard let cg, pxW >= 1, pxH >= 1, samples.count > 1 else { return }
        let rect = CGRect(x: 0, y: 0, width: pxW, height: pxH)

        // Decay: source-over the screen colour at a low alpha → the prior
        // frame's beam fades exponentially toward the background.
        cg.setBlendMode(.normal)
        cg.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: kPBFadeAlpha)
        cg.fill(rect)

        // Build the trace. A bitmap CGContext is y-up (origin bottom-left), and
        // a high user-y maps to the top row of the image we read back, so a
        // positive sample (mid + …) draws upward — matching the other scopes,
        // which is why the blit below uses `.up`. If it ever reads inverted,
        // flip that orientation to `.downMirrored`.
        let mid = CGFloat(pxH) / 2
        let halfH = CGFloat(pxH) / 2 * 0.92
        let stepX = CGFloat(pxW) / CGFloat(samples.count - 1)

        let path = CGMutablePath()
        for j in 0..<samples.count {
            let s = max(-1, min(1, CGFloat(samples[j]) * kPBGain))
            let x = CGFloat(j) * stepX
            let y = mid + s * halfH
            if j == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        // Additive composite so overlapping / dwelling beam pixels sum toward
        // white — the phosphor burn — with no special-casing.
        cg.setBlendMode(.plusLighter)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)

        cg.addPath(path)
        cg.setLineWidth(kPBGlowWidthPt * scale)
        cg.setStrokeColor(red: glow.r, green: glow.g, blue: glow.b, alpha: kPBGlowAlpha)
        cg.strokePath()

        cg.addPath(path)
        cg.setLineWidth(kPBCoreWidthPt * scale)
        cg.setStrokeColor(red: core.r, green: core.g, blue: core.b, alpha: kPBCoreAlpha)
        cg.strokePath()
    }

    func makeImage() -> CGImage? { cg?.makeImage() }
}

/// sRGB channel extraction — the same idiom `SpectrogramView` uses to feed
/// SwiftUI theme colours into a raw `CGContext`.
private func pbRGB(_ c: Color) -> PBColor {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
    return (n.redComponent, n.greenComponent, n.blueComponent)
}

private func pbMixWhite(_ c: PBColor, _ t: CGFloat) -> PBColor {
    (c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t)
}

struct PhosphorBurnView: View {
    let tap: VizTap

    @Environment(AppState.self) private var state
    @Environment(\.displayScale) private var displayScale

    @State private var buffer = PhosphorBuffer()

    var body: some View {
        let theme = state.theme
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
        Canvas { ctx, size in
            _ = timeline.date

            let scale = max(1, displayScale)
            let pxW = Int((size.width * scale).rounded())
            let pxH = Int((size.height * scale).rounded())

            buffer.ensure(pxW: pxW, pxH: pxH)

            let glow = pbRGB(theme.waveform)
            buffer.step(
                samples: tap.snapshotFloats(count: kPBSampleCount),
                scale: scale,
                bg: pbRGB(theme.visualizerBackground),
                glow: glow,
                core: pbMixWhite(glow, kPBCoreWhiteMix)
            )

            // Opaque screen base (the buffer's faded regions sit below 100%
            // alpha for the first frames), then blit the accumulation bitmap.
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(theme.visualizerBackground))
            if let image = buffer.makeImage() {
                ctx.draw(
                    Image(decorative: image, scale: scale, orientation: .up),
                    in: CGRect(origin: .zero, size: size)
                )
            }

            // Crisp label in the SwiftUI layer (not burned into the bitmap),
            // matching the other visualizers.
            ctx.draw(
                Text("PHOSPHOR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.textSecondary.opacity(0.85))
                    .tracking(0.5),
                at: CGPoint(x: 8, y: 10),
                anchor: .topLeading
            )
        }
        .background(theme.visualizerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

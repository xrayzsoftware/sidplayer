import SwiftUI
import AppKit
import SIDEngine

/// Scrolling spectrogram (a.k.a. waterfall). Each column is a single FFT
/// frame; columns shift left as new ones arrive on the right. Colour maps
/// magnitude through the active theme's `peakGradient`, precomputed into a
/// 256-entry LUT so the per-cell render path stays cheap.
private let kSpecFFTSize = 512
private let kSpecFFTBins = kSpecFFTSize / 2
private let kSpecBands   = 64
private let kSpecHistory = 96

private final class SpectrogramState {
    var history: [[Float]] = Array(
        repeating: [Float](repeating: 0, count: kSpecBands),
        count: kSpecHistory
    )
    /// Index of the *next* column to write — i.e. the oldest column.
    var head: Int = 0

    let fft: FFTAnalyzer?
    private let binIdx: [Int]

    init() {
        fft = FFTAnalyzer(size: kSpecFFTSize)
        binIdx = FFTAnalyzer.logBins(
            bands: kSpecBands, minHz: 50, maxHz: 12_000,
            sampleRate: 44_100, fftSize: kSpecFFTSize
        )
    }

    func tick(tap: VizTap) {
        guard let fft else { return }
        let snap = tap.snapshotFloats(count: kSpecFFTSize)
        guard snap.count == kSpecFFTSize else { return }

        fft.transform(snap)

        var col = [Float](repeating: 0, count: kSpecBands)
        for c in 0..<kSpecBands {
            let mag = fft.magnitude(bin: binIdx[c])
            let db  = 20 * log10f(max(mag * 0.0005, 1e-6))
            col[c]  = max(0, min(1, (db + 80) / 80))
        }
        history[head] = col
        head = (head + 1) % kSpecHistory
    }
}

/// Cached colour LUT for one theme. NSColor extraction is the expensive
/// part; doing it 256 times per theme change is fine.
private final class GradientLUT {
    var themeID: String = ""
    var colors: [Color] = []

    func ensure(theme: AppTheme) {
        guard themeID != theme.id || colors.count != 256 else { return }
        var out: [Color] = []
        out.reserveCapacity(256)
        let stops = theme.peakGradient
        for i in 0..<256 {
            let v = Double(i) / 255.0
            out.append(GradientLUT.colorFor(v, stops: stops))
        }
        colors = out
        themeID = theme.id
    }

    private static func colorFor(_ v: Double, stops: [Color]) -> Color {
        // Match PeakMeterView's gradient stop placement: 0 / .55 / .80 / 1.
        let s0 = NSColor(stops[0]).usingColorSpace(.sRGB) ?? .black
        let s1 = NSColor(stops[1]).usingColorSpace(.sRGB) ?? .black
        let s2 = NSColor(stops[2]).usingColorSpace(.sRGB) ?? .black
        let s3 = NSColor(stops[3]).usingColorSpace(.sRGB) ?? .black

        func mix(_ a: NSColor, _ b: NSColor, _ t: Double) -> Color {
            let r  = a.redComponent   + (b.redComponent   - a.redComponent)   * t
            let g  = a.greenComponent + (b.greenComponent - a.greenComponent) * t
            let bl = a.blueComponent  + (b.blueComponent  - a.blueComponent)  * t
            return Color(red: r, green: g, blue: bl)
        }

        if v < 0.55 { return mix(s0, s1, v / 0.55) }
        if v < 0.80 { return mix(s1, s2, (v - 0.55) / 0.25) }
        return mix(s2, s3, (v - 0.80) / 0.20)
    }
}

struct SpectrogramView: View {
    let tap: VizTap
    @Environment(AppState.self) private var state

    @State private var spec = SpectrogramState()
    @State private var lut  = GradientLUT()
    @State private var tick: UInt64 = 0
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let theme = state.theme
        Canvas { ctx, size in
            _ = tick
            spec.tick(tap: tap)
            lut.ensure(theme: theme)

            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(theme.visualizerBackground)
            )

            let padTop:    CGFloat = 18
            let padBottom: CGFloat = 4
            let padX:      CGFloat = 6
            let area = CGRect(
                x: padX, y: padTop,
                width:  size.width  - padX * 2,
                height: size.height - padTop - padBottom
            )
            let colW  = area.width  / CGFloat(kSpecHistory)
            let bandH = area.height / CGFloat(kSpecBands)

            for x in 0..<kSpecHistory {
                let idx = (spec.head + x) % kSpecHistory  // oldest → leftmost
                let col = spec.history[idx]
                let xPos = area.minX + CGFloat(x) * colW
                for c in 0..<kSpecBands {
                    let v = col[c]
                    if v < 0.02 { continue }
                    let lutIdx = min(255, Int(v * 255))
                    // Low frequencies at the bottom, high at the top.
                    let yPos = area.maxY - CGFloat(c + 1) * bandH
                    let cell = CGRect(
                        x: xPos,
                        y: yPos,
                        width:  colW + 0.5,
                        height: bandH + 0.5
                    )
                    ctx.fill(Path(cell), with: .color(lut.colors[lutIdx]))
                }
            }

            ctx.draw(
                Text("WATERFALL")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.textSecondary.opacity(0.85))
                    .tracking(0.5),
                at: CGPoint(x: 8, y: 10),
                anchor: .topLeading
            )
        }
        .background(theme.visualizerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onReceive(timer) { _ in tick &+= 1 }
    }
}

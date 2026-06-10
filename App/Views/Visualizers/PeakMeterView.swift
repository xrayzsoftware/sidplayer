import SwiftUI
import SIDEngine

private let kFFTSize = 1024
private let kFFTBins = kFFTSize / 2
private let kBands   = 40

/// Reference-typed FFT state so we can mutate inside the Canvas closure
/// without triggering SwiftUI re-renders.
private final class PeakMeterState {
    /// Smoothed instantaneous magnitude per band, 0...1.
    var bandLevels = [Float](repeating: 0, count: kBands)
    /// Decaying peak hold per band, 0...1.
    var peakLevels = [Float](repeating: 0, count: kBands)

    let fft: FFTAnalyzer?
    private let binIdx: [Int]

    init() {
        fft = FFTAnalyzer(size: kFFTSize)
        binIdx = FFTAnalyzer.logBins(
            bands: kBands, minHz: 50, maxHz: 12_000,
            sampleRate: 44_100, fftSize: kFFTSize
        )
    }

    /// Decays all bands toward zero. Used while playback is paused/stopped —
    /// the tap still holds the last pre-pause samples, and re-running the FFT
    /// over them would freeze the bars at a stale spectrum instead.
    func decayToSilence() {
        for c in 0..<kBands {
            bandLevels[c] = max(0, bandLevels[c] - 0.040)
            peakLevels[c] = max(0, peakLevels[c] - 0.012)
        }
    }

    /// Updates `bandLevels` (smoothed) and `peakLevels` (decaying caps).
    func tick(tap: VizTap) {
        guard let fft else { return }
        let snap = tap.snapshotFloats(count: kFFTSize)
        guard snap.count == kFFTSize else { return }

        fft.transform(snap)

        for c in 0..<kBands {
            let bin = binIdx[c]
            // Average a small neighbourhood for visual stability.
            var sum: Float = 0
            var n: Int = 0
            for k in max(1, bin - 1)...min(kFFTBins - 1, bin + 1) {
                sum += fft.magnitude(bin: k)
                n += 1
            }
            let mag = sum / Float(max(n, 1))

            // Log-compress to 0..1.
            let db = 20 * log10f(max(mag * 0.0005, 1e-6))
            let v = max(0, min(1, (db + 80) / 80))

            // Bar: snappy attack, slow decay.
            if v > bandLevels[c] {
                bandLevels[c] = 0.55 * bandLevels[c] + 0.45 * v
            } else {
                bandLevels[c] = max(v, bandLevels[c] - 0.040)
            }

            // Peak: jumps up on a new max, drops slowly otherwise.
            if bandLevels[c] >= peakLevels[c] {
                peakLevels[c] = bandLevels[c]
            } else {
                peakLevels[c] = max(0, peakLevels[c] - 0.012)
            }
        }
    }
}

struct PeakMeterView: View {
    let tap: VizTap
    @Environment(AppState.self) private var state

    @State private var meter = PeakMeterState()

    var body: some View {
        let theme = state.theme
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
        Canvas { ctx, size in
            _ = timeline.date
            if state.isPlaying {
                meter.tick(tap: tap)
            } else {
                meter.decayToSilence()
            }

            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(theme.visualizerBackground))

            let padTop:    CGFloat = 18
            let padBottom: CGFloat = 4
            let padX:      CGFloat = 8
            let area = CGRect(
                x: padX,
                y: padTop,
                width: size.width - padX * 2,
                height: size.height - padTop - padBottom
            )
            let bandW = area.width / CGFloat(kBands)
            let barW = max(1.5, bandW * 0.9)

            for c in 0..<kBands {
                let x  = area.minX + CGFloat(c) * bandW + (bandW - barW) / 2
                let level = CGFloat(meter.bandLevels[c])
                let peak  = CGFloat(meter.peakLevels[c])

                let barH = level * area.height
                let bar = CGRect(
                    x: x,
                    y: area.maxY - barH,
                    width: barW,
                    height: max(0, barH)
                )
                if bar.height > 0.5 {
                    let stops = theme.peakGradient
                    ctx.fill(
                        Path(bar),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: stops[0], location: 0.0),
                                .init(color: stops[1], location: 0.55),
                                .init(color: stops[2], location: 0.80),
                                .init(color: stops[3], location: 1.0),
                            ]),
                            startPoint: CGPoint(x: x, y: area.maxY),
                            endPoint:   CGPoint(x: x, y: area.minY)
                        )
                    )
                }

                // Peak cap
                let py = area.maxY - peak * area.height
                let cap = CGRect(x: x, y: py - 1, width: barW, height: 2)
                let capColor: Color = peak > 0.9 ? theme.peakCapHot : theme.peakCap
                ctx.fill(Path(cap), with: .color(capColor))
            }

            ctx.draw(
                Text("PEAKS")
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

import SwiftUI
import Accelerate
import SIDEngine

private let kFFTSize = 1024
private let kFFTBins = kFFTSize / 2
private let kCols    = 64
private let kRows    = 48

/// Reference-typed buffer so we can mutate inside a Canvas body without
/// triggering SwiftUI re-renders. TimelineView drives the cadence.
private final class WaterfallBuffer {
    var rows: [[Float]] = Array(repeating: Array(repeating: 0, count: kCols),
                                count: kRows)

    private let setup: FFTSetup
    private var realIn  = [Float](repeating: 0, count: kFFTSize)
    private var imagIn  = [Float](repeating: 0, count: kFFTSize)
    private var window  = [Float](repeating: 0, count: kFFTSize)
    private var binIdx: [Int] = []   // log-spaced fft-bin index per output column

    init() {
        setup = vDSP_create_fftsetup(vDSP_Length(log2(Float(kFFTSize))), FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(kFFTSize), Int32(vDSP_HANN_NORM))

        // Log-spaced mapping: ~50 Hz → ~12 kHz across kCols.
        // Bin = freq * fftSize / sampleRate. At 44.1kHz, bin width ≈ 43 Hz.
        let minHz: Float = 50
        let maxHz: Float = 12_000
        let sampleRate: Float = 44_100
        binIdx = (0..<kCols).map { i in
            let t = Float(i) / Float(kCols - 1)
            let hz = minHz * powf(maxHz / minHz, t)
            let b = Int((hz * Float(kFFTSize) / sampleRate).rounded())
            return min(max(b, 1), kFFTBins - 1)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func tick(tap: VizTap) {
        let snap = tap.snapshotFloats(count: kFFTSize)
        guard snap.count == kFFTSize else { return }

        // Apply Hann window → real input.
        vDSP_vmul(snap, 1, window, 1, &realIn, 1, vDSP_Length(kFFTSize))
        for i in 0..<kFFTSize { imagIn[i] = 0 }

        var splitComplex = DSPSplitComplex(
            realp: realIn.withUnsafeMutableBufferPointer { $0.baseAddress! },
            imagp: imagIn.withUnsafeMutableBufferPointer { $0.baseAddress! }
        )

        // In-place forward FFT.
        let log2n = vDSP_Length(log2(Float(kFFTSize)))
        realIn.withUnsafeMutableBufferPointer { rb in
            imagIn.withUnsafeMutableBufferPointer { ib in
                var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        // Magnitudes for the bins we care about.
        var newRow = [Float](repeating: 0, count: kCols)
        for c in 0..<kCols {
            let bin = binIdx[c]
            let re = realIn[bin]
            let im = imagIn[bin]
            let mag = sqrtf(re * re + im * im)
            // Log-compress and normalise. The 0.0005 floor keeps log() bounded.
            let db = 20 * log10f(max(mag * 0.0005, 1e-6))   // ~ -120…0 dB
            let n = (db + 80) / 80                            // map to 0..1
            newRow[c] = max(0, min(1, n))
        }

        // Smoothing over time: blend with previous bottom row.
        if let last = rows.last {
            for i in 0..<kCols {
                newRow[i] = 0.65 * newRow[i] + 0.35 * last[i]
            }
        }

        rows.removeFirst()
        rows.append(newRow)
    }
}

struct WaterfallSpectrumView: View {
    let tap: VizTap

    @State private var buf = WaterfallBuffer()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                buf.tick(tap: tap)

                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black))

                let cellW = size.width  / CGFloat(kCols)
                let cellH = size.height / CGFloat(kRows)

                // Newest row at the bottom; oldest at the top.
                for r in 0..<kRows {
                    let row = buf.rows[r]
                    let y = CGFloat(r) * cellH
                    for c in 0..<kCols {
                        let v = row[c]
                        if v < 0.02 { continue }
                        let color = heatmapColor(v)
                        let rect = CGRect(
                            x: CGFloat(c) * cellW,
                            y: y,
                            width: cellW + 0.5,
                            height: cellH + 0.5
                        )
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }

                ctx.draw(
                    Text("SPECTRUM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .tracking(0.5),
                    at: CGPoint(x: 8, y: 10),
                    anchor: .topLeading
                )
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// Five-stop gradient: black → deep blue → green → yellow → red.
    private func heatmapColor(_ v: Float) -> Color {
        let t = max(0, min(1, v))
        if t < 0.25 {
            return Color(red: 0, green: 0, blue: Double(t / 0.25) * 0.4)
        } else if t < 0.5 {
            let s = (t - 0.25) / 0.25
            return Color(red: 0, green: Double(s) * 0.85, blue: Double(0.4 - s * 0.4))
        } else if t < 0.75 {
            let s = (t - 0.5) / 0.25
            return Color(red: Double(s), green: 0.85, blue: 0)
        } else {
            let s = (t - 0.75) / 0.25
            return Color(red: 1.0, green: Double(0.85 - s * 0.7), blue: 0)
        }
    }
}

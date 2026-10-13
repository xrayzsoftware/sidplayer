import Foundation
import SIDEngine
import WinampSkin

/// Feeds the skin's 19-bar spectrum analyser from the player's PCM tap.
/// Same FFT and smoothing as PeakMeterView, at Winamp's bar count.
final class WinampAnalyser {
    private static let fftSize = 1024
    private static let bands = MainWindow.barCount

    private(set) var bars = [Float](repeating: 0, count: bands)
    private(set) var peaks = [Float](repeating: 0, count: bands)

    private let fft = FFTAnalyzer(size: fftSize)
    private let binIndex = FFTAnalyzer.logBins(
        bands: bands, minHz: 50, maxHz: 12_000,
        sampleRate: 44_100, fftSize: fftSize
    )

    /// Lets the bars fall while playback is paused or stopped — the tap still
    /// holds the last samples, and transforming them again would freeze the
    /// bars where they were.
    func decay() {
        for band in 0..<Self.bands {
            bars[band] = max(0, bars[band] - 0.08)
            peaks[band] = max(0, peaks[band] - 0.024)
        }
    }

    func tick(tap: VizTap) {
        guard let fft else { return }
        let samples = tap.snapshotFloats(count: Self.fftSize)
        guard samples.count == Self.fftSize else { return }
        fft.transform(samples)

        for band in 0..<Self.bands {
            let bin = binIndex[band]
            var sum: Float = 0
            var count = 0
            for k in max(1, bin - 1)...min(Self.fftSize / 2 - 1, bin + 1) {
                sum += fft.magnitude(bin: k)
                count += 1
            }
            let decibels = 20 * log10f(max(sum / Float(max(count, 1)) * 0.0005, 1e-6))
            let level = max(0, min(1, (decibels + 80) / 80))

            // Quick to rise, slow to fall; the peak cap falls slower still.
            // Rates are per tick at 30 ticks a second.
            if level > bars[band] {
                bars[band] = 0.4 * bars[band] + 0.6 * level
            } else {
                bars[band] = max(level, bars[band] - 0.08)
            }
            peaks[band] = bars[band] >= peaks[band] ? bars[band] : max(0, peaks[band] - 0.024)
        }
    }
}

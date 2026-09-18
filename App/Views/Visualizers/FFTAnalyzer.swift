import Accelerate

/// Hann-windowed real FFT wrapper. Failable init returns nil if the
/// vDSP setup can't be created (resource exhaustion, non-power-of-two
/// size); callers fall back to a blank canvas instead of crashing.
final class FFTAnalyzer {
    let size: Int
    let bins: Int

    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private var realIn: [Float]
    private var imagIn: [Float]
    private var window: [Float]
    private var windowed: [Float]

    init?(size: Int) {
        guard size > 0, size & (size - 1) == 0 else { return nil }
        let log2n = vDSP_Length(log2(Float(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup  = setup
        self.log2n  = log2n
        self.size   = size
        self.bins   = size / 2
        // zrip's split-complex input is size/2 each: even samples in realp,
        // odd samples in imagp (packed by vDSP_ctoz).
        self.realIn = [Float](repeating: 0, count: size / 2)
        self.imagIn = [Float](repeating: 0, count: size / 2)
        self.window = [Float](repeating: 0, count: size)
        self.windowed = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Apply Hann window to `snap` and run forward FFT in place.
    /// `snap.count` must equal `size`.
    func transform(_ snap: [Float]) {
        vDSP_vmul(snap, 1, window, 1, &windowed, 1, vDSP_Length(size))
        let half = size / 2
        realIn.withUnsafeMutableBufferPointer { rb in
            imagIn.withUnsafeMutableBufferPointer { ib in
                var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                // Feeding the whole signal as "real" made zrip transform only
                // the first half of the window: every band an octave off and
                // the top half mirrored.
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    @inline(__always) func magnitude(bin: Int) -> Float {
        let re = realIn[bin]
        let im = imagIn[bin]
        return sqrtf(re * re + im * im)
    }

    /// Log-spaced bin index map between `minHz` and `maxHz`.
    static func logBins(
        bands: Int,
        minHz: Float,
        maxHz: Float,
        sampleRate: Float,
        fftSize: Int
    ) -> [Int] {
        let bins = fftSize / 2
        // Single-band degenerate case: avoid divide-by-zero on `bands - 1`.
        // Return the bin for `minHz` (the t=0 value the loop would produce).
        guard bands > 1 else {
            guard bands == 1 else { return [] }
            let b = Int((minHz * Float(fftSize) / sampleRate).rounded())
            return [min(max(b, 1), bins - 1)]
        }
        return (0..<bands).map { i in
            let t  = Float(i) / Float(bands - 1)
            let hz = minHz * powf(maxHz / minHz, t)
            let b  = Int((hz * Float(fftSize) / sampleRate).rounded())
            return min(max(b, 1), bins - 1)
        }
    }
}

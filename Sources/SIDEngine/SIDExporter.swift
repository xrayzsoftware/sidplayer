import Foundation

// MARK: - Standalone export function

/// Renders one subtune of a SID file to a 44.1 kHz / mono / 16-bit PCM WAV.
/// All inputs are value types so this is safe to call from a detached Task
/// while the live player is running.
///
/// - Parameters:
///   - path:        Absolute filesystem path to the .sid file.
///   - song:        1-based subtune index to render.
///   - durationMs:  How many milliseconds to render (from HVSC Songlengths).
///   - sampleRate:  Sample rate in Hz (typically 44100).
///   - config:      Emulation settings to apply.
///   - destination: File URL to write. Created (or overwritten) by this call.
public func exportSIDToWAV(
    path: String,
    song: Int,
    durationMs: Int,
    sampleRate: Int,
    config: EmulationConfig,
    to destination: URL
) throws {
    let totalSamples = Int(Double(durationMs) / 1000.0 * Double(sampleRate))
    guard totalSamples > 0 else { throw ExportError.zeroDuration }

    // Dedicated engine — never touches the live playback instance.
    let exportEngine = SIDPlayerEngine()
    let (kernal, basic, chargen) = SIDPlayer.bundleROMData()
    exportEngine.setROMs(kernal: kernal, basic: basic, chargen: chargen)
    exportEngine.applyConfig(config)
    try exportEngine.load(path: path)
    try exportEngine.start(song: song, sampleRate: sampleRate)

    // A WAV of Songlengths duration is tens of MB, so buffer the PCM in memory
    // and write once, atomically. This can never clobber an existing file with
    // a corrupt partial: on any failure the destination is untouched.
    // (The 4 GB RIFF field limit is unreachable for any real Songlengths
    // entry, but a corrupt one shouldn't trap on the UInt32 conversions.)
    let pcmBytes = totalSamples * 2
    guard pcmBytes <= Int(UInt32.max) - 36 else { throw ExportError.outputTooLarge }
    var pcm = Data(capacity: pcmBytes)

    let chunkSize = 4096
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: chunkSize)
    defer { scratch.deallocate() }

    var rendered = 0
    while rendered < totalSamples {
        let want = min(chunkSize, totalSamples - rendered)
        let got  = exportEngine.render(into: scratch, count: want)
        if got <= 0 {
            // The emulator stopped early (init failure, corrupt tune data).
            // Fail loud instead of writing a silently truncated file.
            throw ExportError.renderStalled(renderedMs: rendered * 1000 / sampleRate,
                                            requestedMs: durationMs)
        }
        // Int16 LE PCM — arm64/x86 are both little-endian; no byte swap needed.
        scratch.withMemoryRebound(to: UInt8.self, capacity: got * 2) {
            pcm.append($0, count: got * 2)
        }
        rendered += got
    }

    let dataBytes = UInt32(rendered * 2)
    let fileBytes = dataBytes + 36  // total file size minus the 8-byte RIFF descriptor
    var file = sidWAVHeader(sampleRate: UInt32(sampleRate),
                            dataBytes: dataBytes,
                            fileBytes: fileBytes)
    file.append(pcm)
    try file.write(to: destination, options: .atomic)
}

// MARK: - SIDPlayer ROM helper

public extension SIDPlayer {
    /// Loads kernal/basic/chargen ROMs from the main bundle.
    /// Used by both the live player's `loadBundledROMs()` and the export path.
    static func bundleROMData() -> (kernal: Data?, basic: Data?, chargen: Data?) {
        let bundle = Bundle.main
        func load(_ name: String) -> Data? {
            if let url = bundle.url(forResource: name, withExtension: "rom", subdirectory: "ROMs") {
                return try? Data(contentsOf: url)
            }
            if let url = bundle.url(forResource: name, withExtension: "rom") {
                return try? Data(contentsOf: url)
            }
            return nil
        }
        return (load("kernal"), load("basic"), load("chargen"))
    }
}

// MARK: - WAV header

/// Builds a standard 44-byte RIFF/WAV header for 16-bit mono PCM.
/// Internal (not private) so tests can pin the exact byte layout.
func sidWAVHeader(sampleRate: UInt32, dataBytes: UInt32, fileBytes: UInt32) -> Data {
    var d = Data(capacity: 44)
    // RIFF chunk descriptor
    d += sidFourCC("RIFF")
    d += sidLE32(fileBytes)
    d += sidFourCC("WAVE")
    // fmt sub-chunk (16 bytes of payload)
    d += sidFourCC("fmt ")
    d += sidLE32(16)             // sub-chunk size
    d += sidLE16(1)              // audio format: PCM
    d += sidLE16(1)              // channels: mono
    d += sidLE32(sampleRate)
    d += sidLE32(sampleRate * 2) // byte rate = SR × 1 ch × 2 bytes/sample
    d += sidLE16(2)              // block align = 1 ch × 2 bytes/sample
    d += sidLE16(16)             // bits per sample
    // data sub-chunk header
    d += sidFourCC("data")
    d += sidLE32(dataBytes)
    return d
}

private func sidFourCC(_ s: String) -> Data { Data(s.utf8) }
private func sidLE16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
private func sidLE32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

// MARK: - Error type

public enum ExportError: LocalizedError, Sendable {
    case noTuneLoaded
    case zeroDuration
    case cannotCreateFile(String)
    case renderStalled(renderedMs: Int, requestedMs: Int)
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .noTuneLoaded: return "No tune is loaded — play a tune before exporting."
        case .zeroDuration:  return "Song length is zero; cannot export."
        case .cannotCreateFile(let path): return "Couldn't create the output file at \(path)."
        case .renderStalled(let renderedMs, let requestedMs):
            return String(format: "The emulator stopped %.1f s into a %.1f s export — the tune may be corrupt or unsupported.",
                          Double(renderedMs) / 1000, Double(requestedMs) / 1000)
        case .outputTooLarge: return "The requested duration is too long to export."
        }
    }
}

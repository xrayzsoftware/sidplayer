import Foundation

/// Points at an extracted HVSC tree on disk. Wraps the conventional layout:
/// ```
///   <root>/
///     MUSICIANS/...
///     DEMOS/...
///     GAMES/...                    (newer HVSC releases)
///     DOCUMENTS/Songlengths.md5
///     DOCUMENTS/STIL.txt
/// ```
public struct HVSCSource: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var songlengthsURL: URL { root.appendingPathComponent("DOCUMENTS/Songlengths.md5") }
    public var stilURL:        URL { root.appendingPathComponent("DOCUMENTS/STIL.txt") }

    /// Subdirectories the indexer should walk.
    public static let tuneDirs = ["MUSICIANS", "DEMOS", "GAMES"]

    /// Returns the existing tune subdirectories (some HVSC builds omit GAMES).
    public func availableTuneDirs() -> [URL] {
        Self.tuneDirs
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Throws if the layout doesn't look like HVSC.
    public func validate() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: songlengthsURL.path) else {
            throw HVSCError.missingFile("DOCUMENTS/Songlengths.md5")
        }
        if availableTuneDirs().isEmpty {
            throw HVSCError.missingDirectory("MUSICIANS / DEMOS / GAMES")
        }
    }
}

public enum HVSCError: LocalizedError, Equatable {
    case missingFile(String)
    case missingDirectory(String)
    case manifestParseFailed(String)
    case extractionFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let p):       return "missing file: \(p)"
        case .missingDirectory(let p):  return "missing directory: \(p)"
        case .manifestParseFailed(let s): return "couldn't parse HVSC manifest: \(s)"
        case .extractionFailed(let s):  return "extraction failed: \(s)"
        case .networkError(let s):      return "network error: \(s)"
        }
    }
}

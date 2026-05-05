import Foundation

/// Parses HVSC's `DOCUMENTS/STIL.txt` (SID Tune Information List).
///
/// Format: each entry begins with a path line starting with `/`, followed by
/// metadata lines (`TITLE:`, `ARTIST:`, `COMMENT:`, `NAME:`, ...) plus indented
/// continuation lines. Sections are separated by blank lines and `### ...`
/// headers.
///
/// We don't deeply structure entries — we keep the raw text per path so the UI
/// can render it verbatim. That's what users expect to see in a SID player.
public struct STIL: Sendable {
    public typealias Path = String

    public let entries: [Path: String]

    public init(text: String) {
        var out: [Path: String] = [:]
        out.reserveCapacity(80_000)

        var currentKey: Path? = nil
        var buffer: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            while let last = buffer.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                buffer.removeLast()
            }
            if !buffer.isEmpty {
                out[key] = buffer.joined(separator: "\n")
            }
            buffer.removeAll(keepingCapacity: true)
        }

        text.enumerateLines { line, _ in
            let trimmedFront = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedFront.hasPrefix("###") {
                flush()
                currentKey = nil
                return
            }
            if trimmedFront.hasPrefix("#") { return }
            if line.hasPrefix("/") && line.hasSuffix(".sid") {
                flush()
                currentKey = line
                return
            }
            if currentKey != nil { buffer.append(line) }
        }
        flush()
        self.entries = out
    }

    public init(contentsOf url: URL) throws {
        // STIL.txt ships as ISO-8859-1. Try UTF-8 first for forward compat,
        // fall back to Latin-1 (which is what the file actually is).
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            self.init(text: utf8)
            return
        }
        let latin1 = try String(contentsOf: url, encoding: .isoLatin1)
        self.init(text: latin1)
    }

    /// Lookup. The catalog stores paths without a leading slash; either form works.
    public func entry(forCatalogPath catalogPath: String) -> String? {
        let key = catalogPath.hasPrefix("/") ? catalogPath : "/" + catalogPath
        return entries[key]
    }
}

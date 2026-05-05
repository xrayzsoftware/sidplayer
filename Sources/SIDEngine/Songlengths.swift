import Foundation

/// Parses HVSC's `DOCUMENTS/Songlengths.md5` (HVSC#68+ format).
///
/// File shape:
/// ```
/// ; Header comment block
/// ; /MUSICIANS/H/Hubbard_Rob/Commando.sid
/// 6d019ecba831a9f853675aac29a61c10=3:05 0:55 1:01 0:34 ...
/// ```
public struct Songlengths: Sendable {
    public typealias MD5 = String

    /// Per-subtune lengths in milliseconds, indexed by zero-based subtune.
    public let lengthsByMD5: [MD5: [Int]]

    public init(lengthsByMD5: [MD5: [Int]]) {
        self.lengthsByMD5 = lengthsByMD5
    }

    public func length(md5: MD5, subtune: Int) -> Int? {
        guard let arr = lengthsByMD5[md5.lowercased()], subtune < arr.count else { return nil }
        return arr[subtune]
    }

    public init(text: String) {
        var out: [MD5: [Int]] = [:]
        out.reserveCapacity(60_000)  // HVSC #82 has ~55k entries

        var idx = text.startIndex
        let end = text.endIndex
        while idx < end {
            let lineEnd = text[idx...].firstIndex(of: "\n") ?? end
            let line = text[idx..<lineEnd]
            idx = lineEnd < end ? text.index(after: lineEnd) : end

            if line.isEmpty || line.first == ";" { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let md5 = line[..<eq].lowercased()
            guard md5.count == 32 else { continue }

            let lengths = Self.parseDurations(line[text.index(after: eq)...])
            if !lengths.isEmpty { out[md5] = lengths }
        }
        self.lengthsByMD5 = out
    }

    public init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    /// Parses a whitespace-separated list of durations like "3:05 0:55.123".
    /// Returns each duration in milliseconds.
    static func parseDurations<S: StringProtocol>(_ s: S) -> [Int] {
        var result: [Int] = []
        for token in s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) {
            if let ms = parseDuration(token) { result.append(ms) }
        }
        return result
    }

    /// "M:SS" or "M:SS.mmm" → milliseconds.
    static func parseDuration<S: StringProtocol>(_ s: S) -> Int? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        guard let mins = Int(s[..<colon]) else { return nil }
        let rest = s[s.index(after: colon)...]
        let dot = rest.firstIndex(of: ".")
        let secsStr = dot.map { rest[..<$0] } ?? rest[...]
        guard let secs = Int(secsStr) else { return nil }
        var ms = (mins * 60 + secs) * 1000
        if let d = dot {
            let frac = rest[rest.index(after: d)...]
            // Pad/truncate to 3 digits
            let padded = (frac + "000").prefix(3)
            if let f = Int(padded) { ms += f }
        }
        return ms
    }
}

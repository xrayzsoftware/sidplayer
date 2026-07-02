import Foundation
import CryptoKit

/// A demoscene release that a SID tune was used in (from CSDb's `<UsedIn>`).
struct CSDbRelease: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var type: String
    var year: Int?
    var url: URL? { URL(string: "https://csdb.dk/release/?id=\(id)") }
}

/// A resolved csdb.dk lookup. `sidId == nil` means the tune was looked up but
/// has no CSDb entry (a definitive negative, safe to cache).
struct CSDbEntry: Codable, Sendable {
    var sidId: Int?
    var name: String?
    var author: String?
    var released: String?
    var hvscPath: String?
    var releases: [CSDbRelease]

    var found: Bool { sidId != nil }
    var pageURL: URL? { sidId.flatMap { URL(string: "https://csdb.dk/sid/?id=\($0)") } }

    static let notFound = CSDbEntry(sidId: nil, name: nil, author: nil,
                                    released: nil, hvscPath: nil, releases: [])

    /// True when this entry's CSDb HVSCPath matches the tune we looked up — the
    /// guard against a search mis-pairing a path with a neighbouring SID link.
    func matchesPath(_ target: String) -> Bool {
        guard let p = hvscPath else { return false }
        return p.compare(target, options: .caseInsensitive) == .orderedSame
    }
}

/// Resolves an HVSC SID file to its csdb.dk entry and caches the result to disk.
///
/// CSDb's webservice only resolves by internal numeric id, so we first scrape
/// the SID search page (which pairs each `/sid/?id=N` link with the SID's HVSC
/// path) to map path → id, then fetch the structured `type=sid` XML. Both
/// "found" and "not on CSDb" are cached; transient network failures are not, so
/// a later play retries.
actor CSDbService {
    private let cacheDir: URL
    private let session: URLSession
    private var memo: [String: CSDbEntry] = [:]

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
        self.session = URLSession(configuration: .ephemeral)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// `path` is the HVSC-relative path as stored in the catalog
    /// (e.g. `MUSICIANS/H/Hubbard_Rob/Commando.sid`). `title` improves the
    /// search hit-rate when the filename differs from the tune's title.
    func entry(forHVSCPath path: String, title: String?) async -> CSDbEntry? {
        if let m = memo[path] { return m }
        if let disk = loadCache(path) { memo[path] = disk; return disk }
        guard let e = await fetch(path: path, title: title) else { return nil }
        memo[path] = e
        saveCache(path, e)
        return e
    }

    // MARK: Fetch

    private func fetch(path: String, title: String?) async -> CSDbEntry? {
        let target = path.hasPrefix("/") ? path : "/" + path
        var sawResults = false
        for query in searchQueries(path: path, title: title) {
            guard let url = searchURL(query: query) else { continue }
            // CSDb sometimes answers with an empty body (rate-limit / bad query);
            // treat that as a transient miss, not "not on CSDb".
            guard let html = await getString(url), !html.isEmpty else { continue }
            sawResults = true
            guard let sidId = resolveCandidate(html: html, target: target) else { continue }
            // A failed detail fetch is transient → nil (don't cache).
            guard let details = await fetchDetails(sidId: sidId) else { return nil }
            // Reject only on an explicit HVSCPath mismatch — that's the
            // mis-pairing guard (3884→3883). When CSDb has no HVSCPath at all,
            // trust the id: resolveCandidate already matched the play link's
            // path, and treating "untagged" as a mismatch would cache a
            // permanent false .notFound for a tune that IS on CSDb.
            if details.hvscPath == nil || details.matchesPath(target) { return details }
        }
        // Searched and either found nothing or only mismatches → not on CSDb.
        // No usable response at all → transient, don't cache.
        return sawResults ? .notFound : nil
    }

    private func fetchDetails(sidId: Int) async -> CSDbEntry? {
        guard let url = sidWebserviceURL(id: sidId),
              let data = await getData(url) else { return nil }
        let delegate = SIDXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // A malformed response (rate-limit HTML with a 200 status, truncation)
        // is transient → nil, so it isn't cached as a definitive answer.
        guard parser.parse() else { return nil }
        var releases = delegate.releases
        releases.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        if releases.count > 60 { releases = Array(releases.prefix(60)) }
        return CSDbEntry(
            sidId: sidId,
            name: delegate.sidName.isEmpty ? nil : delegate.sidName,
            author: delegate.sidAuthor.isEmpty ? nil : delegate.sidAuthor,
            released: delegate.sidReleased.isEmpty ? nil : delegate.sidReleased,
            hvscPath: delegate.sidHVSCPath.isEmpty ? nil : delegate.sidHVSCPath,
            releases: releases
        )
    }

    /// Pair each play link (carrying the HVSC path) with the SID link in the
    /// *same* anchor pair — CSDb renders `…X.sid"><img…></a><a href="/sid/?id=N">`
    /// per result row — and return the id whose path matches the target. A loose
    /// "next /sid/ after the path" can grab a neighbouring row's id, so the
    /// pairing is anchored to the exact row markup.
    private func resolveCandidate(html: String, target: String) -> Int? {
        let pattern = #"href="([^"]*?\.sid)"><img[^>]*></a><a href="/sid/\?id=(\d+)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            // href is the full play URL; the HVSC path is its tail.
            if href.range(of: target, options: [.caseInsensitive, .anchored, .backwards]) != nil {
                return Int(ns.substring(with: m.range(at: 2)))
            }
        }
        return nil
    }

    private func searchQueries(path: String, title: String?) -> [String] {
        var qs: [String] = []
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            qs.append(t)
        }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        qs.append(stem.replacingOccurrences(of: "_", with: " "))
        // De-dup preserving order.
        var seen = Set<String>()
        return qs.filter { seen.insert($0.lowercased()).inserted }
    }

    private func searchURL(query: String) -> URL? {
        var comp = URLComponents(string: "https://csdb.dk/search/")
        comp?.queryItems = [
            URLQueryItem(name: "seinsel", value: "sids"),
            URLQueryItem(name: "search", value: query),
        ]
        return comp?.url
    }

    private func sidWebserviceURL(id: Int) -> URL? {
        var comp = URLComponents(string: "https://csdb.dk/webservice/")
        comp?.queryItems = [
            URLQueryItem(name: "type", value: "sid"),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "depth", value: "2"),
        ]
        return comp?.url
    }

    // MARK: Networking

    private func getData(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("SIDPlayer (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func getString(_ url: URL) async -> String? {
        guard let d = await getData(url) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    // MARK: Disk cache

    private func cacheURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(name + ".json")
    }

    private func loadCache(_ key: String) -> CSDbEntry? {
        guard let data = try? Data(contentsOf: cacheURL(key)) else { return nil }
        return try? JSONDecoder().decode(CSDbEntry.self, from: data)
    }

    private func saveCache(_ key: String, _ entry: CSDbEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheURL(key), options: .atomic)
    }
}

/// Minimal delegate for CSDb's `type=sid` XML. Matches by element path so the
/// SID-level `Name`/`Author` aren't clobbered by a nested release's `Group`
/// fields, and release fields are read only when their immediate parent is the
/// `<Release>` under `<UsedIn>`.
private final class SIDXMLParser: NSObject, XMLParserDelegate {
    var sidName = "", sidAuthor = "", sidReleased = "", sidHVSCPath = ""
    var releases: [CSDbRelease] = []

    private var path: [String] = []
    private var buffer = ""
    private var cur: (id: Int, name: String, type: String, year: Int?)?

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        path.append(el)
        buffer = ""
        if el == "Release", path.suffix(2).elementsEqual(["UsedIn", "Release"]) {
            cur = (0, "", "", nil)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if cur != nil, path.suffix(2).elementsEqual(["Release", el]) {
            switch el {
            case "ID":          if cur!.id == 0 { cur!.id = Int(text) ?? 0 }
            case "Name":        if cur!.name.isEmpty { cur!.name = text }
            case "Type":        if cur!.type.isEmpty { cur!.type = text }
            case "ReleaseYear": if cur!.year == nil { cur!.year = Int(text) }
            default: break
            }
        } else if path.suffix(2).elementsEqual(["SID", el]) {
            switch el {
            case "Name":     sidName = text
            case "Author":   sidAuthor = text
            case "Released": sidReleased = text
            case "HVSCPath": sidHVSCPath = text
            default: break
            }
        }
        if el == "Release", path.suffix(2).elementsEqual(["UsedIn", "Release"]), let c = cur {
            if c.id != 0 || !c.name.isEmpty {
                releases.append(CSDbRelease(id: c.id, name: c.name, type: c.type, year: c.year))
            }
            cur = nil
        }
        path.removeLast()
    }
}

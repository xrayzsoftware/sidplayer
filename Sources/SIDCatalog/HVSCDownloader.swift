import Foundation
import SWCompression

/// Downloads the latest HVSC archive (7z) and extracts it via SWCompression's
/// pure-Swift 7z reader. Apple's `Compression` framework doesn't understand
/// 7z, and the App Sandbox forbids shelling out to /usr/bin/tar.
public final class HVSCDownloader: NSObject, @unchecked Sendable {
    public struct Phase: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case discoveringManifest
            case downloading(downloaded: Int64, total: Int64?)
            case extracting
            case done
        }
        public let kind: Kind
    }

    public typealias ProgressHandler = @Sendable (Phase) -> Void

    /// HVSC's manifest endpoint. Returns the 7z URL and current version.
    public static let manifestURL = URL(string: "https://hvsc.c64.org/api/v1/version/7z")!

    public override init() { super.init() }

    private struct Manifest: Decodable {
        let version: Int
        struct Pkg: Decodable { let url: URL }
        let complete: Pkg
    }

    public struct Result: Sendable {
        public let version: Int
        public let source: HVSCSource
    }

    /// Discover the latest HVSC version and its complete-archive URL.
    public func discoverLatest() async throws -> (version: Int, archiveURL: URL) {
        let (data, response) = try await URLSession.shared.data(from: Self.manifestURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HVSCError.networkError("manifest HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do {
            let m = try JSONDecoder().decode(Manifest.self, from: data)
            return (m.version, m.complete.url)
        } catch {
            throw HVSCError.manifestParseFailed(error.localizedDescription)
        }
    }

    /// Download + extract HVSC into `destination`. Existing contents are
    /// removed. Final layout under `destination`:
    ///   destination/C64Music/MUSICIANS/...
    ///   destination/C64Music/DOCUMENTS/Songlengths.md5
    /// (HVSC's archive packs everything inside a top-level "C64Music" dir.)
    public func downloadAndExtract(
        to destination: URL,
        progress: ProgressHandler? = nil
    ) async throws -> Result {
        let fm = FileManager.default

        progress?(.init(kind: .discoveringManifest))
        let (version, archiveURL) = try await discoverLatest()

        // 1. Download to a temp file.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("hvsc-\(version).7z", isDirectory: false)
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }

        try await downloadFile(
            from: archiveURL,
            to: tmp,
            progress: { downloaded, total in
                progress?(.init(kind: .downloading(downloaded: downloaded, total: total)))
            }
        )

        // 2. Extract via SWCompression's pure-Swift 7z reader. The whole 7z
        // is loaded into memory (≈250 MB for current HVSC), then each entry's
        // payload is decompressed lazily inside `SevenZipContainer.open`.
        // Sandbox-safe — no Process spawn.
        progress?(.init(kind: .extracting))
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            let archiveData = try Data(contentsOf: tmp, options: [.mappedIfSafe])
            let entries = try SevenZipContainer.open(container: archiveData)
            for entry in entries {
                try Self.extract(entry: entry, into: destination)
            }
        } catch let err as HVSCError {
            throw err
        } catch {
            throw HVSCError.extractionFailed("7z: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: tmp)

        // 3. Locate the C64Music root inside the extracted tree (HVSC archives
        // wrap content in a single top-level dir, name varies by release).
        let root = try Self.locateHVSCRoot(under: destination)
        let source = HVSCSource(root: root)
        try source.validate()

        progress?(.init(kind: .done))
        return Result(version: version, source: source)
    }

    /// Writes a single 7z entry to disk under `destination`. Rejects
    /// absolute paths and `..` components so a malicious archive can't
    /// escape the destination tree.
    private static func extract(entry: SevenZipEntry, into destination: URL) throws {
        let name = entry.info.name
        guard !name.isEmpty, !name.hasPrefix("/") else { return }
        let components = name.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw HVSCError.extractionFailed("rejected path with ..: \(name)")
        }
        let outURL = components.reduce(destination) { $0.appendingPathComponent($1) }
        let fm = FileManager.default

        switch entry.info.type {
        case .directory:
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        case .regular:
            let parent = outURL.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = entry.data ?? Data()
            try data.write(to: outURL, options: .atomic)
        default:
            // Symlinks, devices, etc. — HVSC archives don't use them.
            break
        }
    }

    /// Walk the top level of `dir` and find the directory containing
    /// `DOCUMENTS/Songlengths.md5`. Searches one level deep.
    public static func locateHVSCRoot(under dir: URL) throws -> URL {
        let fm = FileManager.default
        let probe: (URL) -> Bool = { url in
            fm.fileExists(atPath: url.appendingPathComponent("DOCUMENTS/Songlengths.md5").path)
        }
        if probe(dir) { return dir }
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            if probe(entry) { return entry }
        }
        throw HVSCError.missingDirectory("HVSC root (DOCUMENTS/Songlengths.md5 not found)")
    }

    // MARK: - Streaming download with progress

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progress: @escaping (Int64, Int64?) -> Void
    ) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (asyncBytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HVSCError.networkError("download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw HVSCError.extractionFailed("couldn't open \(destination.path) for writing")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20) // 1 MB
        var totalWritten: Int64 = 0
        var nextReport: Int64 = 0
        let reportEvery: Int64 = 512 * 1024  // 512 KB granularity

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                totalWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if totalWritten >= nextReport {
                    progress(totalWritten, total)
                    nextReport = totalWritten + reportEvery
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
        }
        progress(totalWritten, total)
    }
}

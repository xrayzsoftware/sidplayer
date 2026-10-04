import Foundation

/// Minimal client for the Ultimate firmware REST API (Ultimate 64, Ultimate-II+,
/// Commodore 64 Ultimate). Only what the "Play on C64 Ultimate" output target
/// needs: identify the device, push a .sid to its built-in player, and
/// pause/resume/reset the machine.
///
/// Reference: https://1541u-documentation.readthedocs.io/en/latest/api/api_calls.html
actor UltimateClient {
    struct Info: Decodable {
        let product: String?
        let firmwareVersion: String?
        let hostname: String?

        enum CodingKeys: String, CodingKey {
            case product, hostname
            case firmwareVersion = "firmware_version"
        }

        var summary: String {
            [product, firmwareVersion.map { "firmware \($0)" }, hostname]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ErrorEnvelope: Decodable { let errors: [String]? }

    private let base: URL
    private let password: String?
    private let session: URLSession

    /// `host` is an IP or hostname, optionally with a scheme and port.
    init?(host: String, password: String?) {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if !h.contains("://") { h = "http://" + h }
        guard let url = URL(string: h), url.host != nil else { return nil }
        base = url
        let pw = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.password = pw.isEmpty ? nil : pw
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        session = URLSession(configuration: cfg)
    }

    func info() async throws -> Info {
        let data = try await request("GET", "v1/info")
        return try JSONDecoder().decode(Info.self, from: data)
    }

    /// Uploads a .sid and starts it on the Ultimate's own SID player. `song`
    /// is 1-based; nil plays the file's default song.
    func playSID(_ sid: Data, song: Int?) async throws {
        var query: [String: String] = [:]
        if let song { query["songnr"] = String(song) }
        _ = try await request("POST", "v1/runners:sidplay", query: query, body: sid)
    }

    func pause() async throws  { _ = try await request("PUT", "v1/machine:pause") }
    func resume() async throws { _ = try await request("PUT", "v1/machine:resume") }
    func reset() async throws  { _ = try await request("PUT", "v1/machine:reset") }

    // MARK: -

    private func request(_ method: String, _ path: String,
                         query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw Failure(message: "bad Ultimate URL")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw Failure(message: "bad Ultimate URL") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        if let password { req.setValue(password, forHTTPHeaderField: "X-Password") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Failure(message: "C64 Ultimate unreachable: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            throw Failure(message: "C64 Ultimate rejected the network password")
        }
        // The firmware reports problems in an `errors` array, usually with a
        // 2xx status, so check the body as well as the status code.
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let errs = env.errors, !errs.isEmpty {
            throw Failure(message: "C64 Ultimate: \(errs.joined(separator: "; "))")
        }
        guard (200..<300).contains(status) else {
            throw Failure(message: "C64 Ultimate returned HTTP \(status)")
        }
        return data
    }
}

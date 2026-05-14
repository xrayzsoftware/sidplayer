import Foundation

/// Persists the user's chosen HVSC root across launches via a security-scoped
/// bookmark in UserDefaults. Sandbox-aware: when running unsandboxed (current
/// build), the `.withSecurityScope` flag is a harmless no-op. When sandbox is
/// enabled (pass 2), the bookmark is what keeps the grant alive.
///
/// Callers MUST balance `resolve()` with `release()` — the resolved URL holds
/// a security scope until `stopAccessingSecurityScopedResource()` is called.
enum HVSCBookmark {
    private static let key = "hvscRootBookmark.v1"

    static func save(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Best-effort persistence; non-sandboxed builds can still operate
            // off the in-memory hvscSource for the current launch.
        }
    }

    /// Resolves to a URL and begins security-scoped access. Returns nil if no
    /// bookmark exists or it can no longer be resolved (folder moved, etc.).
    /// Caller must invoke `release(url)` when done.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        if stale {
            // Refresh the stored bookmark so subsequent resolves are cheap.
            save(url)
        }
        return url
    }

    static func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

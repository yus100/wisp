import Foundation

/// Bearer for xAI speech-to-text, taken from the same login Grok Build uses.
///
/// Grok keeps a short-lived (~15 min) OAuth access token in `~/.grok/auth.json` and rotates it under a
/// file lock. Rather than touching the refresh token ourselves, an expired token is refreshed by running
/// an authenticated grok command, after which the new token is read back from disk.
enum GrokAuth {
    struct NotSignedIn: LocalizedError {
        var errorDescription: String? { "Voice needs a Grok login. Run `grok login` in a terminal, or set XAI_API_KEY." }
    }

    static func bearer(env: [String: String], grokPath: String?) async throws -> String {
        if let key = env["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let token = freshToken() { return token }
        if let grokPath {
            appLog("auth: access token stale, asking grok to refresh it")
            await refresh(grokPath: grokPath, env: env)
            if let token = freshToken() { return token }
        }
        throw NotSignedIn()
    }

    /// Kicks off a refresh in the background when the token is close to expiry, so voice starts instantly.
    static func prefetch(env: [String: String], grokPath: String?) {
        guard env["XAI_API_KEY"]?.isEmpty ?? true, freshToken(margin: 180) == nil, let grokPath else { return }
        Task.detached { await refresh(grokPath: grokPath, env: env) }
    }

    static func freshToken(margin: TimeInterval = 60) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var best: (String, Date)?
        for case let entry as JSON in root.values {
            guard let key = entry["key"] as? String, !key.isEmpty,
                  let expiresText = entry["expires_at"] as? String,
                  let expires = parser.date(from: expiresText) ?? plain.date(from: expiresText) else { continue }
            if expires.timeIntervalSinceNow > margin, best == nil || expires > best!.1 {
                best = (key, expires)
            }
        }
        return best?.0
    }

    private static func refresh(grokPath: String, env: [String: String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: grokPath)
            process.arguments = ["models"]
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                appLog("auth: could not run grok models: \(error)")
                continuation.resume()
            }
        }
    }
}

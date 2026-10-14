import Foundation

/// The bearer for xAI speech-to-text, taken from the login Grok Build already has.
///
/// Grok keeps a short-lived (about 15 minute) OAuth access token in `auth.json` and rotates it under a
/// file lock. Wisp never touches the refresh token: when the token is stale it runs an authenticated
/// grok command (`grok models`), which refreshes the token and writes it back, then reads it again.
public enum GrokCredentials {
    public enum Failure: LocalizedError, Equatable {
        case notSignedIn

        public var errorDescription: String? {
            "Voice needs a Grok login. Run `grok login` in a terminal, or set XAI_API_KEY in your shell profile."
        }
    }

    public static func bearer(environment: [String: String], grokHome: URL, grok: URL?) async throws -> String {
        if let key = environment["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        let authFile = grokHome.appending(path: "auth.json")
        if let token = freshToken(in: authFile) { return token }
        if let grok {
            Log.info("voice: access token is stale; asking grok to refresh it")
            await refresh(grok: grok, environment: environment)
            if let token = freshToken(in: authFile) { return token }
        }
        throw Failure.notSignedIn
    }

    /// Refreshes in the background when the token is close to expiry, so voice starts without waiting.
    public static func prefetch(environment: [String: String], grokHome: URL, grok: URL?) {
        guard environment["XAI_API_KEY"]?.isEmpty ?? true, let grok,
            freshToken(in: grokHome.appending(path: "auth.json"), margin: 180) == nil
        else { return }
        Task.detached { await refresh(grok: grok, environment: environment) }
    }

    static func freshToken(in authFile: URL, now: Date = Date(), margin: TimeInterval = 60) -> String? {
        guard let data = try? Data(contentsOf: authFile) else { return nil }
        return freshToken(inAuthJSON: data, now: now, margin: margin)
    }

    /// The access token with the latest expiry that is still valid `margin` seconds from now.
    static func freshToken(inAuthJSON data: Data, now: Date, margin: TimeInterval) -> String? {
        struct Login: Decodable {
            let key: String?
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case key
                case expiresAt = "expires_at"
            }
        }
        guard let logins = try? JSONDecoder().decode([String: Login].self, from: data) else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        return logins.values
            .compactMap { login -> (String, Date)? in
                guard let key = login.key, !key.isEmpty, let text = login.expiresAt,
                    let expiry = (try? withFraction.parse(text)) ?? (try? plain.parse(text))
                else { return nil }
                return (key, expiry)
            }
            .filter { $0.1.timeIntervalSince(now) > margin }
            .max { $0.1 < $1.1 }?.0
    }

    private static func refresh(grok: URL, environment: [String: String]) async {
        do {
            _ = try await ProcessRunner.run(grok, arguments: ["models"], environment: environment, timeout: .seconds(30))
        } catch {
            Log.info("voice: could not run grok models: \(error.localizedDescription)")
        }
    }
}

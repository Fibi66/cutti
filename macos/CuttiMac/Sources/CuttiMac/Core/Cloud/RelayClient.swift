import Foundation

/// Client-side helper for the cutti cloud relay.
///
/// All AI calls go through the relay at `https://api.cutti.app`. There is
/// no provider choice, no UserDefaults override, no direct-to-Azure path —
/// one production backend, period. Local development can change the
/// `relayBaseURL` constant below and rebuild.
enum RelayClient {
    /// Canonical relay origin. Hardcoded: a greenfield app with a single
    /// production backend has no reason to read this from UserDefaults.
    static let relayBaseURL = "https://api.cutti.app"

    /// Default chat model name surfaced in logs. The Worker actually picks
    /// the model — this string is informational only.
    static let defaultModel = "gpt-5.4-mini"

    /// Returns a relay-backed `OpenAIConfiguration`. The `apiKey` field
    /// carries either a session JWT (prefixed `"jwt:"`), a dev token
    /// (prefixed `"dev:"`), or an empty string (not signed in yet —
    /// requests will 401 and the UI prompts the user to sign in).
    ///
    /// `OpenAIClient` switches the Authorization header based on the prefix.
    static func configurationFromDefaults() -> OpenAIConfiguration {
        // Prefer the session JWT (real user identity, credits tracked).
        // `currentBearerToken()` is nonisolated and lock-protected, so this
        // works from MainActor and from background tasks alike — we
        // intentionally do not require `@MainActor` here so callers on
        // background actors (e.g. `ImageGenerationService`) can invoke it
        // without an extra hop that risks deadlocking under cancellation.
        if let jwt = RelaySession.currentBearerToken(), !jwt.isEmpty {
            return .cuttiRelay(baseURL: relayBaseURL, sessionToken: "jwt:\(jwt)", model: defaultModel)
        }

        // Dev token: lets internal builds hit the worker without a
        // StoreKit / sign-in flow. Optional — if absent we return an
        // empty-token config so the request 401s deliberately.
        let dev = UserDefaults.standard.string(forKey: "cutti_relay_dev_token") ?? ""
        if !dev.isEmpty {
            return .cuttiRelay(baseURL: relayBaseURL, sessionToken: "dev:\(dev)", model: defaultModel)
        }

        return .cuttiRelay(baseURL: relayBaseURL, sessionToken: "", model: defaultModel)
    }
}

import Foundation
import Combine
import os

/// Observable source of truth for "is the user signed in + what's their
/// subscription + how many credits left this period". Owns the session
/// JWT (stored in Keychain) and the live credits counter.
///
/// Populated by two paths:
/// 1. **Apple StoreKit** → `SubscriptionManager` POSTs the JWS to
///    `/v1/auth/apple` → this session stashes the returned JWT.
/// 2. **Email + password** → `signIn()` / `signUp()` → `/v1/auth/signin`
///    or `/v1/auth/signup` → this session stashes the returned JWT. Web
///    checkout binds the resulting subscription to the user automatically
///    via the Stripe webhook.
/// 3. **Auto refresh** → 401 on any relay call triggers `refresh()`.
///
/// `RelayClient.configurationFromDefaults()` asks us for the current
/// Bearer token so every OpenAIClient call flows through the worker
/// with the user's real identity — no shared dev token in production.
@MainActor
final class RelaySession: ObservableObject {
    static let shared = RelaySession()

    // MARK: - Published state

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var user: User? = nil {
        didSet {
            let id = user?.id
            Self.updateSnapshot { $0.userID = id }
        }
    }
    @Published private(set) var subscription: Subscription? = nil
    @Published private(set) var credits: Credits? = nil
    /// Quality / cost tier the user has selected. Mirrors
    /// `users.quality_mode` on the server. Default `"smart"` so a
    /// signed-out / freshly-signed-in user shows the right radio
    /// before the first /v1/me round-trip lands.
    @Published private(set) var qualityMode: String = "smart"
    @Published private(set) var lastError: String? = nil
    @Published private(set) var isRefreshing: Bool = false

    // MARK: - Types mirroring /v1/me contract

    struct User: Codable, Equatable {
        let id: String
        let email: String?
        let source: String  // "apple" | "stripe" | "email" | "dev"
        let createdAt: Int?
        let emailVerified: Bool?
        /// Server-authoritative quality_mode. Optional for backward
        /// compatibility with older /v1/me responses.
        let qualityMode: String?

        enum CodingKeys: String, CodingKey {
            case id, email, source
            case createdAt = "created_at"
            case emailVerified = "email_verified"
            case qualityMode = "quality_mode"
        }
    }

    struct Subscription: Codable, Equatable {
        let plan: String   // "monthly" | "yearly" | "free"
        let status: String // "active" | "expired" | "grace"
        let renewalAt: Int?
        let cancelAtPeriodEnd: Bool?

        enum CodingKeys: String, CodingKey {
            case plan, status
            case renewalAt = "renewal_at"
            case cancelAtPeriodEnd = "cancel_at_period_end"
        }
    }

    struct Credits: Codable, Equatable {
        let quota: Int
        let used: Int
        let remaining: Int
        /// Pack credits remaining. Never expire, purchased separately
        /// from the subscription (see /v1/checkout/pack). Absent on
        /// older server builds — decodes to 0.
        let balancePack: Int
        /// Subscription + pack credits. This is the real "what the user
        /// can still spend" number. Falls back to `remaining` for older
        /// servers that only return the sub bucket.
        let balanceTotal: Int
        /// Lifetime total of pack credits ever granted to this user.
        /// Used to draw a progress bar (used = total − balance).
        let packTotalGranted: Int
        let periodResetAt: Int?

        enum CodingKeys: String, CodingKey {
            case quota, used, remaining
            case balancePack = "balance_pack"
            case balanceTotal = "balance_total"
            case packTotalGranted = "pack_total_granted"
            case periodResetAt = "period_reset_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quota = try c.decode(Int.self, forKey: .quota)
            used = try c.decode(Int.self, forKey: .used)
            remaining = try c.decode(Int.self, forKey: .remaining)
            balancePack = (try? c.decode(Int.self, forKey: .balancePack)) ?? 0
            balanceTotal = (try? c.decode(Int.self, forKey: .balanceTotal)) ?? remaining
            packTotalGranted = (try? c.decode(Int.self, forKey: .packTotalGranted)) ?? 0
            periodResetAt = try? c.decode(Int.self, forKey: .periodResetAt)
        }

        init(quota: Int, used: Int, remaining: Int, balancePack: Int = 0,
             balanceTotal: Int? = nil, packTotalGranted: Int = 0,
             periodResetAt: Int? = nil) {
            self.quota = quota
            self.used = used
            self.remaining = remaining
            self.balancePack = balancePack
            self.balanceTotal = balanceTotal ?? (remaining + balancePack)
            self.packTotalGranted = packTotalGranted
            self.periodResetAt = periodResetAt
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(quota, forKey: .quota)
            try c.encode(used, forKey: .used)
            try c.encode(remaining, forKey: .remaining)
            try c.encode(balancePack, forKey: .balancePack)
            try c.encode(balanceTotal, forKey: .balanceTotal)
            try c.encode(packTotalGranted, forKey: .packTotalGranted)
            try c.encodeIfPresent(periodResetAt, forKey: .periodResetAt)
        }

        var percentUsed: Double {
            guard quota > 0 else { return 0 }
            return min(1.0, Double(used) / Double(quota))
        }

        /// Fraction of lifetime-granted pack credits that have been
        /// consumed. 0 when no packs have ever been granted.
        var packPercentUsed: Double {
            guard packTotalGranted > 0 else { return 0 }
            let used = max(0, packTotalGranted - balancePack)
            return min(1.0, Double(used) / Double(packTotalGranted))
        }
    }

    // MARK: - Init

    private init() {
        let initialToken = KeychainStore.string(for: Self.accessTokenAccount)
        self.accessToken = initialToken
        self.isSignedIn = initialToken != nil
        // Seed the nonisolated snapshot before the first background read.
        // didSet on `accessToken` fires only on subsequent assignments, not
        // on the initializer write, so we mirror it explicitly here.
        Self.updateSnapshot {
            $0.accessToken = initialToken
            $0.userID = nil
        }

        NotificationCenter.default.addObserver(
            forName: RelayCreditsNotification.name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo?[RelayCreditsNotification.payloadKey]
                as? RelayCreditsNotification.Payload else { return }
            Task { @MainActor in
                self?.apply(payload: payload)
            }
        }

        // Fire a background /v1/me refresh on boot so the progress bar
        // is accurate before the user opens Settings.
        if isSignedIn {
            Task { await self.refreshMe() }
        }
    }

    // MARK: - Token storage

    private static let accessTokenAccount = "session.access_token"

    private var accessToken: String? {
        didSet {
            let token = accessToken
            KeychainStore.setString(token, for: Self.accessTokenAccount)
            Self.updateSnapshot { $0.accessToken = token }
            isSignedIn = token != nil
            if token == nil {
                user = nil
                subscription = nil
                credits = nil
            }
        }
    }

    /// Read-only snapshot for `RelayClient`/`OpenAIClient` to attach as
    /// `Authorization: Bearer <...>`. Returns nil when the user hasn't
    /// signed in yet.
    ///
    /// `nonisolated` so background actors (e.g. `FullAnalysisPipeline`,
    /// `CloudRemotionRenderer`) can read it without hopping to the main
    /// queue. Backed by a lock-protected snapshot kept in sync with the
    /// MainActor-owned `accessToken` via `didSet`.
    nonisolated func bearerToken() -> String? { Self.currentBearerToken() }

    // MARK: - Nonisolated credential snapshot
    //
    // RelaySession itself is `@MainActor` because it owns `@Published`
    // UI state. But the bearer token + user id are read from arbitrary
    // actor contexts (analysis pipeline, image generation, overlay
    // renderer factory) and they need a thread-safe path that does NOT
    // assert MainActor isolation. We mirror those two scalars into a
    // lock-protected `CredentialSnapshot`; writers always run on
    // MainActor (via the `didSet` hooks above) and readers go through
    // the lock from any thread.

    private struct CredentialSnapshot: Sendable {
        var accessToken: String?
        var userID: String?
    }

    nonisolated private static let credentialSnapshot = OSAllocatedUnfairLock<CredentialSnapshot>(
        initialState: CredentialSnapshot()
    )

    nonisolated private static func updateSnapshot(_ mutate: @Sendable (inout CredentialSnapshot) -> Void) {
        credentialSnapshot.withLock { mutate(&$0) }
    }

    /// Thread-safe bearer token read. Returns nil if the user is not
    /// signed in (or has signed out). Safe to call from any actor.
    nonisolated static func currentBearerToken() -> String? {
        credentialSnapshot.withLock { $0.accessToken }
    }

    /// Thread-safe signed-in user id read. Returns nil before `/v1/me`
    /// has populated the user profile (or after sign-out). Safe to call
    /// from any actor.
    nonisolated static func currentUserID() -> String? {
        credentialSnapshot.withLock { $0.userID }
    }

    // MARK: - Base URL

    private var relayBaseURL: String { RelayClient.relayBaseURL }

    // MARK: - Public operations

    /// Email + password sign-up. Creates an account shell that has no
    /// subscription yet — the user subscribes via the web pricing page
    /// after signing in.
    func signUp(email: String, password: String) async throws {
        try await postAuth(path: "/v1/auth/signup", body: [
            "email": email, "password": password,
        ])
    }

    /// Email + password sign-in.
    func signIn(email: String, password: String) async throws {
        try await postAuth(path: "/v1/auth/signin", body: [
            "email": email, "password": password,
        ])
    }

    /// Asks the Worker to resend the email verification link. Requires
    /// an authenticated session; the endpoint is rate-limited to once
    /// per minute per user.
    func resendVerification() async throws {
        let base = relayBaseURL
        guard let token = accessToken else {
            throw RelaySessionError.misconfigured("Sign in first.")
        }
        let url = URL(string: "\(base.trimmingTrailingSlash)/v1/auth/resend-verification")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfNotOK(resp: resp, data: data)
    }

    private func postAuth(path: String, body: [String: Any]) async throws {
        let base = relayBaseURL
        let url = URL(string: "\(base.trimmingTrailingSlash)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfNotOK(resp: resp, data: data)
        try ingestAuthResponse(data: data)
    }

    /// Called by `SubscriptionManager` after StoreKit returns a signed
    /// transaction. The worker validates with Apple's keys and mints a JWT.
    func exchangeAppleTransaction(signedTransactionInfo: String,
                                  bundleId: String,
                                  environment: String) async throws {
        let base = relayBaseURL
        let url = URL(string: "\(base.trimmingTrailingSlash)/v1/auth/apple")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "signedTransactionInfo": signedTransactionInfo,
            "bundleId": bundleId,
            "environment": environment,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfNotOK(resp: resp, data: data)
        try ingestAuthResponse(data: data)
    }

    /// Pull fresh subscription / credits state from /v1/me. Called on
    /// app launch, after any auth mutation, and periodically from
    /// `SubscriptionView`.
    func refreshMe() async {
        guard let token = accessToken else { return }
        let base = relayBaseURL
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let url = URL(string: "\(base.trimmingTrailingSlash)/v1/me")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                // Token is stale. Try one refresh; if that also fails
                // or still 401s, drop the session so the UI falls back
                // to the signed-out state instead of showing "Sign out"
                // with no account data.
                do {
                    _ = try await rotate()
                    await refreshMe()
                } catch {
                    signOut()
                }
                return
            }
            try Self.throwIfNotOK(resp: resp, data: data)
            let payload = try JSONDecoder().decode(MeResponse.self, from: data)
            self.user = payload.user
            self.subscription = payload.subscription
            self.credits = payload.credits
            if let mode = payload.user.qualityMode { self.qualityMode = mode }
            self.lastError = nil
        } catch {
            self.lastError = (error as NSError).localizedDescription
        }
    }

    /// Trade an expiring (or recently-expired) JWT for a fresh one. The
    /// worker allows up to a 7-day-old token to refresh before forcing
    /// a full re-login.
    @discardableResult
    func rotate() async throws -> Bool {
        guard let token = accessToken else { return false }
        let base = relayBaseURL
        let url = URL(string: "\(base.trimmingTrailingSlash)/v1/auth/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfNotOK(resp: resp, data: data)
        try ingestAuthResponse(data: data)
        return true
    }

    /// Update the user's quality_mode preference on the server. The
    /// new value is persisted there (so a fresh device picks it up
    /// immediately) AND mirrored locally so the picker doesn't snap
    /// back while the network round-trip is in flight.
    ///
    /// On error the local value is reverted to the prior server value.
    func setQualityMode(_ mode: String) async {
        guard let token = accessToken else { return }
        guard ["smart", "high_quality", "economy"].contains(mode) else { return }
        let previous = qualityMode
        qualityMode = mode
        let base = relayBaseURL
        do {
            let url = URL(string: "\(base.trimmingTrailingSlash)/v1/me/preferences")!
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["quality_mode": mode]
            )
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.throwIfNotOK(resp: resp, data: data)
        } catch {
            qualityMode = previous
            lastError = (error as NSError).localizedDescription
        }
    }

    func signOut() {
        accessToken = nil
        lastError = nil
    }

    // MARK: - Per-feature usage breakdown

    public struct FeatureUsage: Codable, Equatable, Identifiable {
        public let feature: String
        public let calls: Int
        public let credits: Int
        public let lastAt: Int

        public var id: String { feature }
        enum CodingKeys: String, CodingKey {
            case feature, calls, credits
            case lastAt = "last_at"
        }
    }

    private struct UsageByFeatureResponse: Codable {
        let days: Int
        let features: [FeatureUsage]
    }

    /// Fetch the per-feature credit breakdown for the last `days`
    /// days from the relay. Backend aggregates `usage_events` grouped
    /// by the `task` tag we send on every chat call.
    func fetchUsageByFeature(days: Int = 30) async throws -> [FeatureUsage] {
        guard let token = accessToken else { return [] }
        let base = relayBaseURL
        let url = URL(string:
            "\(base.trimmingTrailingSlash)/v1/me/usage/by-feature?days=\(days)"
        )!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfNotOK(resp: resp, data: data)
        let payload = try JSONDecoder().decode(UsageByFeatureResponse.self, from: data)
        return payload.features
    }

    // MARK: - Private

    private func ingestAuthResponse(data: Data) throws {
        let payload = try JSONDecoder().decode(AuthResponse.self, from: data)
        self.accessToken = payload.jwt
        self.user = payload.user
        self.subscription = payload.subscription
        if let credits = payload.credits {
            self.credits = credits
        }
        if let mode = payload.user.qualityMode { self.qualityMode = mode }
        self.lastError = nil
    }

    private func apply(payload: RelayCreditsNotification.Payload) {
        guard let remaining = payload.remaining else { return }
        let quota = payload.quota ?? credits?.quota ?? remaining
        let used = max(0, quota - remaining)
        let reset = payload.periodResetAt.map { Int($0.timeIntervalSince1970) }
            ?? credits?.periodResetAt
        // Credit headers only carry the subscription bucket; keep the
        // pack balance stable until the next /v1/me refresh.
        credits = Credits(
            quota: quota,
            used: used,
            remaining: remaining,
            balancePack: credits?.balancePack ?? 0,
            balanceTotal: nil,
            packTotalGranted: credits?.packTotalGranted ?? 0,
            periodResetAt: reset
        )
    }

    private static func throwIfNotOK(resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw RelaySessionError.network("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RelaySessionError.server(status: http.statusCode,
                                           message: String(body.prefix(200)))
        }
    }

    // MARK: - Response models

    private struct AuthResponse: Decodable {
        let jwt: String
        let expiresAt: Int
        let user: User
        let subscription: Subscription?
        let credits: Credits?

        enum CodingKeys: String, CodingKey {
            case jwt, user, subscription, credits
            case expiresAt = "expires_at"
        }
    }

    private struct MeResponse: Decodable {
        let user: User
        let subscription: Subscription?
        let credits: Credits
    }
}

enum RelaySessionError: LocalizedError {
    case misconfigured(String)
    case network(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .misconfigured(let s):
            // Misconfigured strings are authored by us (e.g. "Sign in
            // to Cutti from Settings before…"), so they're already
            // user-facing.
            return s
        case .network:
            return L("Network error. Please check your connection and try again.")
        case .server(_, let message):
            // Auth endpoints (sign-in / sign-up / resend-verification)
            // return JSON bodies like `{"error":"invalid_credentials"}`
            // on 4xx. Surface a friendly localised message for known
            // codes so the user sees "邮箱或密码不正确。" instead of
            // the generic "服务不可用" fallback when they mistype a
            // password. Unknown codes / 5xx still get the generic
            // message — we never leak the raw body or HTTP status.
            if let mapped = Self.mapKnownErrorCode(in: message) {
                return mapped
            }
            return L("Cutti is temporarily unavailable. Please try again in a moment.")
        }
    }

    /// Substring-matches the raw response body for known relay error
    /// codes and returns the localised user-facing message. Returns
    /// `nil` for unknown / non-auth bodies so the caller falls through
    /// to the generic "temporarily unavailable" message.
    private static func mapKnownErrorCode(in body: String) -> String? {
        if body.contains("invalid_credentials") {
            return L("Email or password is incorrect.")
        }
        if body.contains("invalid_email") {
            return L("Please enter a valid email address.")
        }
        if body.contains("invalid_request") {
            return L("Email and password are required.")
        }
        return nil
    }
}

private enum Host {
    static var name: String {
        ProcessInfo.processInfo.hostName
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

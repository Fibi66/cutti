import Foundation

// MARK: - Configuration

enum OpenAIClientError: Error, LocalizedError, Sendable {
    case invalidResponse(statusCode: Int, body: String)
    case decodingFailed(String)
    case noChoices
    case networkError(String)
    /// Relay rejected the request because the user isn't signed in
    /// (missing/expired/invalid JWT). Surfaced as a friendly prompt
    /// to sign in, not a raw HTTP error.
    case relayAuthRequired
    /// Relay rejected the request because the user's email isn't
    /// verified yet. Their account exists but they haven't clicked
    /// the verification link.
    case relayEmailNotVerified
    /// Relay rejected the request because the user has used up their
    /// monthly credit allowance. `resetAt` is the server-provided
    /// `period_reset_at` epoch — the next refill anchored to the
    /// user's subscription `started_at` day, NOT the 1st of the
    /// calendar month (e.g. signed up on the 17th → resets on the
    /// 17th of every month). See backend `personalNextResetAt`.
    case relayQuotaExceeded(used: Int?, quota: Int?, resetAt: Date?)

    /// True for errors that a short retry might recover from (transient
    /// network blips, 429 rate limits, 5xx server errors).
    var isRetryable: Bool {
        switch self {
        case .networkError:
            return true
        case .invalidResponse(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .decodingFailed, .noChoices,
             .relayAuthRequired, .relayEmailNotVerified, .relayQuotaExceeded:
            return false
        }
    }

    /// User-facing message used by the chat panel.
    var displayMessage: String {
        switch self {
        case .invalidResponse(let status, _):
            // Never include the raw response body — it can leak
            // internal relay diagnostics (credits_used, request_id, …).
            // Map the HTTP status to a friendly localized hint instead.
            switch status {
            case 401:
                return L("Please sign in from Settings.")
            case 403:
                return L("AI is temporarily unavailable. Please try again in a moment.")
            case 404:
                return L("AI is temporarily unavailable. Please try again in a moment.")
            case 429:
                return L("Too many requests right now. Please try again in a moment.")
            case 500...599:
                return L("AI is temporarily unavailable. Please try again in a moment.")
            default:
                return L("AI is temporarily unavailable. Please try again in a moment.")
            }
        case .decodingFailed:
            return L("AI returned an unexpected response. Please try again.")
        case .noChoices:
            return L("AI returned an empty response. Please try again.")
        case .networkError:
            // The OS error string (e.g. "The Internet connection
            // appears to be offline.") is already localized + friendly,
            // but we don't trust every URLError code to be polite, so
            // we use a single canonical line.
            return L("Network error. Please check your connection and try again.")
        case .relayAuthRequired:
            return L("Please sign in from Settings.")
        case .relayEmailNotVerified:
            return L("Please verify your email address before using AI features. Check your inbox for the verification link from Cutti.")
        case .relayQuotaExceeded(let used, let quota, let resetAt):
            return Self.formatQuotaExceeded(used: used, quota: quota, resetAt: resetAt)
        }
    }

    /// Same as `displayMessage`. Conforming to `LocalizedError` means
    /// SwiftUI alerts and any `error.localizedDescription` call site
    /// (banner messages, action-chat failure rows, etc.) all get the
    /// friendly localized text — not the default
    /// "The operation couldn’t be completed. (CuttiMac.OpenAIClientError error N.)"
    var errorDescription: String? {
        displayMessage
    }

    private static func formatQuotaExceeded(
        used: Int?,
        quota: Int?,
        resetAt: Date?
    ) -> String {
        let quotaText: String
        if let used, let quota {
            quotaText = "\(used) / \(quota)"
        } else if let quota {
            quotaText = "\(quota)"
        } else {
            quotaText = "—"
        }
        // Render the server-provided `period_reset_at` as a relative
        // countdown ("Resets in 3 days") rather than an absolute date —
        // the server's reset anchor is the user's subscription start
        // day (not necessarily the 1st), and timezone/locale calendar
        // mismatch would otherwise flip a "Jan 17" into "Jan 16" for
        // users west of the server. The relative phrase is what
        // Settings → Subscription already shows next to the progress
        // bar, so the 402 banner now agrees with it.
        if let resetAt, let phrase = resetCountdownPhrase(for: resetAt) {
            let template = L(
                "You've used your AI credits for this month (%1$@). %2$@. Upgrade to a paid plan for more."
            )
            return String(format: template, quotaText, phrase)
        }
        // No reset date provided (older relay responses, or pre-auth
        // callers). Fall back to a date-free sentence — never invent
        // a reset day.
        let template = L(
            "You've used your AI credits for this month (%@). Upgrade to a paid plan for more."
        )
        return String(format: template, quotaText)
    }

    /// "Resets today" / "Resets in 1 day" / "Resets in N days",
    /// localized. Mirrors `SubscriptionSection.resetCountdownText` so
    /// the 402 banner and the Settings countdown agree on wording.
    /// Returns nil only if the input is so far past that day-count
    /// arithmetic fails — caller treats nil as "skip the phrase".
    private static func resetCountdownPhrase(for resetDate: Date) -> String? {
        let now = Date()
        if resetDate <= now { return L("Resets today") }
        let days = Calendar.current.dateComponents([.day], from: now, to: resetDate).day ?? 0
        if days <= 0 { return L("Resets today") }
        if days == 1 { return L("Resets in 1 day") }
        return L("Resets in %d days", days)
    }
}

/// Configuration for AI calls. Two distinct shapes:
///
///   • Cutti Cloud (`provider == .cuttiCloud`): `relayBaseURL` is the
///     cutti relay origin and `apiKey` is a `"jwt:"` / `"dev:"` prefixed
///     session token interpreted by `OpenAIClient`'s auth switch. The
///     wire request hits `/v1/chat/completions` on the relay, which
///     proxies upstream to Azure / OpenAI.
///
///   • Custom / BYOK (`provider == .custom`): `relayBaseURL` is the
///     user's OpenAI-compatible endpoint root (no `/v1` suffix), `apiKey`
///     is a raw Bearer token, and `model` carries the actual model name
///     (sent in the request body — Cutti Cloud omits `model` because the
///     relay picks it server-side).
struct OpenAIConfiguration: Sendable {
    let provider: AIProviderPreference
    let apiKey: String
    let model: String
    let relayBaseURL: String

    /// Cutti cloud relay configuration.
    static func cuttiRelay(
        baseURL: String,
        sessionToken: String,
        model: String = "gpt-5.4-mini"
    ) -> OpenAIConfiguration {
        OpenAIConfiguration(
            provider: .cuttiCloud,
            apiKey: sessionToken,
            model: model,
            relayBaseURL: baseURL
        )
    }

    #if os(macOS)
    /// Custom OpenAI-compatible endpoint with a user-supplied Bearer key.
    /// `baseURL` should be the API root (e.g. `https://api.openai.com/v1`
    /// or `https://my-proxy.example/v1`); the trailing `/v1` is part of
    /// the user's input. The exact request path appended is
    /// `/chat/completions`.
    ///
    /// macOS-only: iOS is subscription-only, so the BYOK constructor is
    /// compiled out entirely on iOS as a defense-in-depth guard against
    /// any future call site accidentally building a `.custom` config.
    static func custom(
        baseURL: String,
        apiKey: String,
        model: String
    ) -> OpenAIConfiguration {
        OpenAIConfiguration(
            provider: .custom,
            apiKey: apiKey,
            model: model,
            relayBaseURL: baseURL
        )
    }
    #endif

    /// Returns the configured backend. For `.cuttiCloud`, reads the
    /// session JWT / dev token from `RelayClient`. For `.custom`, reads
    /// the user's stored URL/Key/Model from `CuttiSettings`. Returns
    /// `nil` if `.custom` is selected but the configuration is incomplete
    /// (e.g. user hasn't filled in the API key yet).
    ///
    /// Nonisolated: safe to invoke from any actor — both cutti-relay
    /// credentials and BYOK settings are backed by lock-protected stores.
    ///
    /// On iOS this always returns the cuttiCloud configuration: the iOS
    /// app is subscription-only (no BYOK UI, no `CuttiSettings`
    /// AppStorage for the BYOK fields), and the `.custom` path is
    /// compiled out entirely.
    static func fromEnvironment() -> OpenAIConfiguration? {
        #if os(macOS)
        switch CuttiSettings.aiProvider() {
        case .cuttiCloud:
            let config = RelayClient.configurationFromDefaults()
            print("🔑 OpenAI config: provider=cutti_relay base=\(config.relayBaseURL)")
            return config
        case .custom:
            let custom = CuttiSettings.customAIConfiguration()
            guard custom.hasUsableLLMConfig else {
                print("🔑 OpenAI config: provider=custom — not configured (Settings → AI Provider)")
                return nil
            }
            print("🔑 OpenAI config: provider=custom base=\(custom.llmBaseURL) model=\(custom.llmModel)")
            return .custom(
                baseURL: custom.llmBaseURL,
                apiKey: custom.llmApiKey,
                model: custom.llmModel
            )
        }
        #else
        let config = RelayClient.configurationFromDefaults()
        print("🔑 OpenAI config: provider=cutti_relay base=\(config.relayBaseURL)")
        return config
        #endif
    }
}

// MARK: - Request / Response models

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]?
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content, toolCalls: nil, toolCallId: nil)
    }

    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content, toolCalls: nil, toolCallId: nil)
    }

    static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content, toolCalls: nil, toolCallId: nil)
    }

    static func tool(callId: String, content: String) -> ChatMessage {
        ChatMessage(role: "tool", content: content, toolCalls: nil, toolCallId: callId)
    }
}

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: FunctionCall

    struct FunctionCall: Codable, Sendable {
        let name: String
        let arguments: String
    }
}

struct ToolDefinition: Codable, Sendable {
    let type: String
    let function: FunctionDefinition

    struct FunctionDefinition: Codable, Sendable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }

    struct JSONSchema: Codable, Sendable {
        let type: String
        let properties: [String: Property]?
        let required: [String]?
        let items: ItemSchema?

        struct Property: Codable, Sendable {
            let type: String
            let description: String?
            let items: ItemSchema?
        }

        struct ItemSchema: Codable, Sendable {
            let type: String
            let properties: [String: Property]?
            let required: [String]?
        }
    }
}

struct ToolChoice: Codable, Sendable {
    let type: String
    let function: FunctionRef?

    struct FunctionRef: Codable, Sendable {
        let name: String
    }

    static func required(name: String) -> ToolChoice {
        ToolChoice(type: "function", function: FunctionRef(name: name))
    }
}

struct ChatCompletionResponse: Sendable {
    let content: String?
    let toolCalls: [ToolCall]
    let finishReason: String?
}

// MARK: - Client

struct OpenAIClient: Sendable {
    let configuration: OpenAIConfiguration
    /// Max retry attempts for transient errors (network blips, 429, 5xx).
    /// Exposed so tests can override (default: 3 retries = 4 total attempts).
    var maxRetries: Int = 3
    /// Base delay in seconds for exponential backoff. Attempts wait
    /// `baseRetryDelay * 2^attempt` with a small jitter. Default 0.6s →
    /// retries at ~0.6s, ~1.2s, ~2.4s.
    var baseRetryDelay: Double = 0.6

    /// Quality / cost tier hint sent to the relay. The backend has full
    /// authority — it reads the user's persisted `quality_mode` and
    /// combines it with this hint to pick a deployment. Values are
    /// validated server-side; unknown strings are silently ignored.
    enum TaskHint: String, Sendable {
        /// Structural cut work (transcript-driven first cut, dedup,
        /// silence trim). Cheap; fine on mini.
        case firstCut = "first_cut"
        /// B-roll / overlay / image generation prompts. Benefits from
        /// the larger model on smart mode.
        case creative
        /// Free-form chat assistant / tool-using agent. Pro on smart.
        case agent
        /// Mechanical translation of subtitles. Cheap.
        case translate
        /// Remotion overlay generation (animation skill chat path).
        /// Pro on smart — the codegen / template-pick step needs the
        /// stronger model. Tagged distinctly from `creative` so the
        /// per-feature dashboard can split B-roll suggestions from
        /// animation work.
        case animation
    }

    func chatCompletion(
        messages: [ChatMessage],
        tools: [ToolDefinition]? = nil,
        toolChoice: ToolChoice? = nil,
        temperature: Double = 0.7,
        task: TaskHint? = nil
    ) async throws -> ChatCompletionResponse {
        var lastError: OpenAIClientError?
        // One-shot JWT rotation budget. Cutti relay 401s carry
        // `reason: expired` once the user's session JWT has aged out.
        // Rather than show a still-signed-in user "Please sign in
        // from Settings.", we silently swap the token via
        // /v1/auth/refresh and retry the same request. Limited to a
        // single rotation per call to avoid loops if the refresh
        // itself succeeds but the next request still 401s for some
        // unrelated reason.
        var didRotateJWT = false
        // Set on the rotation path so the retry uses the fresh token
        // instead of `self.configuration.apiKey` (which captures the
        // OLD bearer at OpenAIClient construction time).
        var rotatedConfig: OpenAIConfiguration?
        for attempt in 0...maxRetries {
            do {
                return try await performChatCompletion(
                    messages: messages,
                    tools: tools,
                    toolChoice: toolChoice,
                    temperature: temperature,
                    task: task,
                    configurationOverride: rotatedConfig
                )
            } catch let error as OpenAIClientError {
                lastError = error
                if !didRotateJWT,
                   configuration.provider == .cuttiCloud,
                   case .relayAuthRequired = error {
                    didRotateJWT = true
                    if await Self.attemptRelayJWTRotation() {
                        // Rebuild the config so the retry picks up the
                        // new JWT from RelaySession's snapshot. Stay on
                        // the same `attempt` index — rotation isn't an
                        // exponential-backoff retry, it's a one-shot
                        // "your token is stale, here's a fresh one".
                        rotatedConfig = RelayClient.configurationFromDefaults()
                        continue
                    }
                }
                guard error.isRetryable, attempt < maxRetries else { throw error }
                let delay = baseRetryDelay * pow(2.0, Double(attempt))
                let jitter = Double.random(in: 0...(delay * 0.25))
                let ns = UInt64((delay + jitter) * 1_000_000_000)
                print("⚠️ OpenAI attempt \(attempt + 1) failed (\(error)); retrying in \(String(format: "%.2fs", delay + jitter))")
                try? await Task.sleep(nanoseconds: ns)
            } catch {
                let wrapped = OpenAIClientError.networkError(error.localizedDescription)
                lastError = wrapped
                guard attempt < maxRetries else { throw wrapped }
                let delay = baseRetryDelay * pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? .networkError("Unknown failure")
    }

    private func performChatCompletion(
        messages: [ChatMessage],
        tools: [ToolDefinition]? = nil,
        toolChoice: ToolChoice? = nil,
        temperature: Double = 0.7,
        task: TaskHint? = nil,
        configurationOverride: OpenAIConfiguration? = nil
    ) async throws -> ChatCompletionResponse {
        let configuration = configurationOverride ?? self.configuration
        let base = configuration.relayBaseURL.hasSuffix("/")
            ? String(configuration.relayBaseURL.dropLast())
            : configuration.relayBaseURL
        // Cutti relay exposes `/v1/chat/completions` rooted at the relay
        // origin (no `/v1` in the configured base). Custom OpenAI-shape
        // providers expect the user to include `/v1` in the base URL
        // (e.g. `https://api.openai.com/v1`) and we append `/chat/...`.
        let url: URL = {
            switch configuration.provider {
            case .cuttiCloud:
                return URL(string: "\(base)/v1/chat/completions")!
            case .custom:
                return URL(string: "\(base)/chat/completions")!
            }
        }()

        var body: [String: Any] = [
            "messages": try messages.map { try encodeToDictionary($0) },
            "temperature": temperature,
        ]
        switch configuration.provider {
        case .cuttiCloud:
            // Relay forwards payloads byte-identically to Azure, which
            // picks the deployed model — `model` stays out of the body.
            // The `task` hint is server-only; relay strips it before
            // forwarding upstream. Only ever sent to cuttiCloud.
            if let task {
                body["task"] = task.rawValue
            }
            break
        case .custom:
            // Custom OpenAI-compatible servers require `model` in the
            // body; without it most providers 400.
            body["model"] = configuration.model
        }

        if let tools {
            body["tools"] = try tools.map { try encodeToDictionary($0) }
        }
        if let toolChoice {
            body["tool_choice"] = try encodeToDictionary(toolChoice)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = configuration.apiKey
        let authMode: String
        switch configuration.provider {
        case .cuttiCloud:
            // `apiKey` is prefixed by `RelayClient.configurationFromDefaults()`
            // so we know whether to send the dev header or a Bearer JWT.
            if token.hasPrefix("jwt:") {
                request.setValue(
                    "Bearer \(String(token.dropFirst(4)))",
                    forHTTPHeaderField: "Authorization"
                )
                authMode = "jwt(len=\(token.count - 4))"
            } else if token.hasPrefix("dev:") {
                request.setValue(
                    String(token.dropFirst(4)),
                    forHTTPHeaderField: "X-Cutti-Dev-Token"
                )
                authMode = "dev"
            } else if !token.isEmpty {
                // Legacy — raw token with no prefix; treat as dev.
                request.setValue(token, forHTTPHeaderField: "X-Cutti-Dev-Token")
                authMode = "legacy-dev"
            } else {
                authMode = "none"
            }
        case .custom:
            // Standard OpenAI bearer auth.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            authMode = "byok-bearer(len=\(token.count))"
        }

        request.httpBody = jsonData
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAIClientError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.networkError("Non-HTTP response")
        }

        switch configuration.provider {
        case .cuttiCloud:
            // Relay responses carry X-Cutti-Credits-* headers; forward
            // them to any RelaySession observers so the UI progress bar
            // updates live without an extra /v1/me round-trip.
            RelayCreditsNotification.postIfPresent(from: httpResponse)
        case .custom:
            // No credit metering on BYOK — user pays the upstream
            // provider directly.
            break
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            print("⚠️ chat failed: provider=\(configuration.provider.rawValue) status=\(httpResponse.statusCode) auth=\(authMode) body=\(responseBody.prefix(300))")
            // Cutti relay emits structured JSON errors for auth/quota/email
            // problems; the chat panel turns those into plain-language
            // hints. Custom providers aren't expected to share the
            // same shape, so we skip the parse and fall through to the
            // generic error.
            if configuration.provider == .cuttiCloud,
               let structured = Self.parseRelayError(
                   statusCode: httpResponse.statusCode,
                   data: data
               ) {
                throw structured
            }
            throw OpenAIClientError.invalidResponse(
                statusCode: httpResponse.statusCode,
                body: String(responseBody.prefix(500))
            )
        }

        return try parseResponse(data)
    }

    /// Attempt one JWT rotation against the relay. Safe to call from
    /// any actor — `RelaySession.rotate` itself is `@MainActor`-bound,
    /// but `await` from a non-isolated context just hops over.
    ///
    /// Returns true if `RelaySession`'s in-memory snapshot now holds a
    /// fresh token that the next request will pick up. Returns false if
    /// there was no token to rotate (signed-out / dev-token mode), or
    /// if the refresh endpoint itself rejected (>7-day refresh window
    /// has elapsed, or network is unreachable).
    ///
    /// Used by every cuttiCloud relay caller (chat, image-gen,
    /// remotion) as the first reaction to a 401 — rather than telling
    /// a still-signed-in user to "Please sign in from Settings.", we
    /// silently swap the token and retry once. If rotation itself
    /// fails the original 401 surfaces unchanged.
    static func attemptRelayJWTRotation() async -> Bool {
        do {
            return try await RelaySession.shared.rotate()
        } catch {
            return false
        }
    }

    /// Maps a non-200 relay response body (`{"error": "...", ...}`) to
    /// a typed `OpenAIClientError`. Returns nil if the body isn't a
    /// recognised structured error — caller falls through to the
    /// generic `.invalidResponse` path.
    ///
    /// Internal (not private) so tests can exercise the mapping
    /// without going through a live URLSession.
    static func parseRelayError(
        statusCode: Int,
        data: Data
    ) -> OpenAIClientError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? String else {
            // Bare 401 with no body (e.g. before requireAuth wraps its
            // response) still deserves the friendly sign-in message.
            if statusCode == 401 { return .relayAuthRequired }
            return nil
        }
        switch code {
        case "unauthorized":
            return .relayAuthRequired
        case "email_not_verified":
            return .relayEmailNotVerified
        case "quota_exceeded":
            let used = json["credits_used"] as? Int
            let quota = json["credits_quota"] as? Int
            let resetAt = (json["period_reset_at"] as? TimeInterval)
                .map { Date(timeIntervalSince1970: $0) }
            return .relayQuotaExceeded(used: used, quota: quota, resetAt: resetAt)
        default:
            return nil
        }
    }

    // MARK: - Private

    private func parseResponse(_ data: Data) throws -> ChatCompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw OpenAIClientError.noChoices
        }

        let content = message["content"] as? String
        let finishReason = choice["finish_reason"] as? String

        var toolCalls: [ToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for rawCall in rawCalls {
                guard let id = rawCall["id"] as? String,
                      let type = rawCall["type"] as? String,
                      let function = rawCall["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String else {
                    continue
                }
                toolCalls.append(ToolCall(
                    id: id,
                    type: type,
                    function: .init(name: name, arguments: arguments)
                ))
            }
        }

        return ChatCompletionResponse(
            content: content,
            toolCalls: toolCalls,
            finishReason: finishReason
        )
    }

    private func encodeToDictionary<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

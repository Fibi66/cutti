import Foundation

/// Client wrapper for the server-authoritative animation compose path.
///
/// `POST /v1/agents/animation/compose` on the Cutti relay accepts a
/// `ComposeBrief` (facts only — no instructions, no template catalog,
/// no routing rules) and returns a `ComposeResult` carrying the final
/// `template_id` + `props_json` + `duration_seconds` chosen by the
/// server-side AnimationSkill + LLM + validator loop.
///
/// All structural decisions ("which template", "what text on screen",
/// "how to time the items") live in the AnimationSkill bundle on the
/// relay. The Mac client supplies only the spoken context. The result
/// is fed straight into the existing `MediaCoreViewModel.generateOverlay`
/// path so the cache + render flow are unchanged.
struct AnimationComposeClient {
    /// Base URL of the Cutti relay, e.g. `https://api.cutti.app`.
    let relayBaseURL: URL
    /// Bearer token tagged with `jwt:` or `dev:` (same scheme used by
    /// `CloudRemotionRenderer`). Empty string means "not signed in".
    let bearerToken: String
    /// Override hook for tests. Production uses `URLSession.shared`.
    var session: URLSession = .shared
    /// Tests inject a deterministic decoder; production uses the
    /// standard JSON decoder.
    var decoder: JSONDecoder = .init()

    // MARK: - Public

    /// Posts the brief and returns the server's chosen template +
    /// props. Throws `AnimationComposeError` on transport, auth, or
    /// validation failures.
    func compose(_ brief: ComposeBrief) async throws -> ComposeResult {
        let endpoint = relayBaseURL.appendingPathComponent("v1/agents/animation/compose")
        print("🎬 [compose] POST \(endpoint.absoluteString) role=\(brief.section.role) duration=\(brief.section.durationSec)s tokenPrefix=\(bearerToken.prefix(4))")

        // 60s is generous: the server caps the agent loop at 3 LLM
        // iterations and validation is pure JS, so a typical compose
        // completes in 3–8s. We give 60s for cold-start + a triple-
        // retry worst case.
        var req = URLRequest(url: endpoint, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Mirror CloudRemotionRenderer: split the `jwt:` / `dev:`
        // prefix into the right header. Sending the prefix verbatim
        // as `Bearer jwt:<token>` makes the relay try to verify the
        // literal string `jwt:<token>` as a JWT and bail out 401.
        if bearerToken.hasPrefix("jwt:") {
            req.setValue(
                "Bearer \(String(bearerToken.dropFirst(4)))",
                forHTTPHeaderField: "Authorization"
            )
        } else if bearerToken.hasPrefix("dev:") {
            req.setValue(
                String(bearerToken.dropFirst(4)),
                forHTTPHeaderField: "X-Cutti-Dev-Token"
            )
        } else if !bearerToken.isEmpty {
            req.setValue(bearerToken, forHTTPHeaderField: "X-Cutti-Dev-Token")
        }

        do {
            req.httpBody = try JSONEncoder().encode(brief)
        } catch {
            throw AnimationComposeError.encoding(error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AnimationComposeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnimationComposeError.transport("Invalid response from relay (not HTTP).")
        }
        print("🎬 [compose] response status=\(http.statusCode) bytes=\(data.count)")

        guard (200..<300).contains(http.statusCode) else {
            // Reuse OpenAIClient's typed-error mapping so quota / auth
            // failures surface the same UI copy as chat / render.
            print("🎬 [compose] error body (≤512B): \(String(data: data.prefix(512), encoding: .utf8) ?? "<binary>")")
            if let mapped = OpenAIClient.parseRelayError(
                statusCode: http.statusCode,
                data: data
            ) {
                throw AnimationComposeError.relayMessage(mapped.displayMessage)
            }
            throw AnimationComposeError.relayMessage(
                L("Animation generation is temporarily unavailable. Please try again in a moment.")
            )
        }

        do {
            return try decoder.decode(ComposeResult.self, from: data)
        } catch {
            throw AnimationComposeError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Brief / Result types

/// Mirrors `ComposeBrief` in
/// `cutti-backend/.../src/agents/animationCompose.types.ts`. The Mac
/// client builds one of these from a `BRollSuggestionHint` plus a
/// transcript window snapshot. Encoded with `JSONEncoder`'s default
/// (camelCase) key strategy — the server explicitly reads camelCase.
struct ComposeBrief: Codable {
    let language: Language
    let section: Section
    let transcriptWindow: [TranscriptCue]
    /// 1 on the first click. Bumped by the Mac client every time the
    /// user clicks "Generate animation" on the SAME suggestion (without
    /// editing the prompt) so the server can deliberately produce a
    /// different valid take. Also folded into the local cache key so
    /// `OverlayRenderCache` actually re-renders rather than serving
    /// the previous MOV from disk.
    let attempt: Int?
    /// Compact summaries of prior compose passes for THIS suggestion in
    /// THIS app session, oldest first. Capped to the 3 most recent so
    /// the prompt stays small.
    let previousAttempts: [PreviousAttemptSummary]?

    enum Language: String, Codable {
        case en
        case zh
    }

    struct Section: Codable {
        /// Position on the composed timeline where the overlay starts.
        let composedTime: Double
        /// Anchor window length the speaker spends on this moment. The
        /// server is expected to size `durationSeconds` to match.
        let durationSec: Double
        /// Stage-1 section role (intro/thesis/enumeration/process/...).
        /// Drives the validator's role→template strong-nudge rule.
        let role: String
        /// ≤20 char Stage-1 distilled title.
        let userTitle: String?
        /// Stage-1 mini-format payload (e.g. "step1 → step2 → step3").
        let agentHint: String?
        /// Why a visual helps at this moment, in Stage-1's words.
        let rationale: String
        /// Set when the user typed a custom prompt in the suggestion
        /// strip. The agent treats this as the strongest signal.
        let userEdit: String?
    }

    struct TranscriptCue: Codable {
        /// Seconds from the overlay's `composedTime` (0 = overlay starts).
        let relativeSec: Double
        /// ASR text bucket — the server uses this only as a timing
        /// reference, not for verbatim screen text.
        let text: String
    }

    struct PreviousAttemptSummary: Codable {
        let template_id: String
        /// First ~80 chars of the heading / first label / quote — whatever
        /// the prior take's primary screen text was. Used as a concrete
        /// "don't repeat THIS" reference for the LLM.
        let headline: String
    }
}

/// Mirrors `ComposeResult` server-side. `template_id` + `props_json`
/// + `duration_seconds` are the same triple we'd otherwise have built
/// from the agent loop's `generate_overlay` tool call, so the existing
/// `generateOverlay(templateID:propsJSON:durationSeconds:at:)` entry
/// point is unchanged.
struct ComposeResult: Codable {
    let template_id: String
    let props_json: String
    let duration_seconds: Double
    let composed_time: Double
    let iterations: Int
}

// MARK: - Errors

enum AnimationComposeError: LocalizedError {
    case encoding(String)
    case transport(String)
    case decoding(String)
    case relayMessage(String)

    var errorDescription: String? {
        switch self {
        case .encoding(let m): return "Couldn't build animation request: \(m)"
        case .transport(let m): return "Network error: \(m)"
        case .decoding(let m): return "Couldn't read animation response: \(m)"
        case .relayMessage(let m): return m
        }
    }
}

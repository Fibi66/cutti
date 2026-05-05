import Foundation

/// Errors surfaced by `ImageGenerationService`. The `.relayError` case
/// carries the HTTP status + a truncated body so callers can turn
/// 402/403/503 into specific user-facing messages (quota / email
/// verification / provider not configured) without re-parsing the body.
enum ImageGenerationError: Error, LocalizedError {
    case relayNotConfigured
    case invalidResponse
    /// Used by the BYOK path where the upstream error body comes from
    /// the user's OWN provider (OpenAI / Anthropic / etc.). We surface
    /// a truncated body so the user can self-diagnose ("invalid api
    /// key", "rate limit"), since they own that account.
    case relayError(status: Int, body: String)
    /// Pre-localized, user-safe message from our own cloud relay
    /// (quota exhausted, email not verified, sign-in required).
    /// Shown verbatim — callers must NOT stuff raw HTTP bodies in here.
    case relayMessage(String)
    case noImagesReturned
    case fileIOFailed(String)

    var errorDescription: String? {
        switch self {
        case .relayNotConfigured:
            return "Sign in to Cutti (or configure the relay URL) before generating images."
        case .invalidResponse:
            return "The image service returned an unexpected response."
        case .relayError(let status, let body):
            return "Image generation failed (\(status)): \(body.prefix(200))"
        case .relayMessage(let message):
            return message
        case .noImagesReturned:
            return "The image service returned no images."
        case .fileIOFailed(let detail):
            return "Could not save generated image: \(detail)"
        }
    }
}

/// Abstract aspect ratio — NOT a pixel count. The relay maps this to
/// whatever dimensions the current upstream image model actually
/// supports (FLUX-era: 1024×1792 portrait; gpt-image-2-era: 1024×1536;
/// future: something else). Keeping the client model-agnostic means
/// swapping the cloud model is a relay-only change — shipped .app
/// binaries never need a corresponding update.
///
/// Raw values are the wire-format values of the new `aspect` field on
/// POST /v1/images/generations.
enum ImageGenerationSize: String, Codable, Sendable, CaseIterable {
    case square
    case portrait
    case landscape

    /// Legacy alias — kept so old call sites referring to the FLUX-era
    /// name continue to compile. New code should use `.square`.
    static var square1024: ImageGenerationSize { .square }

    var label: String {
        switch self {
        case .square: return "Square (1:1)"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

/// Thin actor that calls the Cutti relay's `/v1/images/generations`
/// route and returns decoded PNG bytes. It deliberately does NOT write
/// to disk — the caller (typically `MediaCoreViewModel`) owns project-
/// directory layout. That separation keeps the service trivially
/// testable with a mocked `URLSession` and matches how `OpenAIClient`
/// is used in the codebase.
///
/// Auth: the service reuses `RelayClient.configurationFromDefaults()`
/// so the JWT / dev-token header logic stays in one place. It mirrors
/// the handling in `OpenAIClient` to avoid drift.
actor ImageGenerationService {
    static let shared = ImageGenerationService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Generate an image and return decoded PNG bytes. Throws
    /// `ImageGenerationError` on any failure.
    ///
    /// `task` is forwarded to the relay as the `task` field on the
    /// request body so the admin dashboard can split image-gen credit
    /// spend by feature. Defaults to `"image_gen"`; pass a more
    /// specific tag (e.g. `"image_chapter_card"`) when a call site
    /// wants finer-grained attribution.
    func generate(
        prompt: String,
        size: ImageGenerationSize = .square1024,
        task: String? = "image_gen"
    ) async throws -> Data {
        #if os(macOS)
        switch CuttiSettings.aiProvider() {
        case .cuttiCloud:
            return try await generateViaCuttiRelay(prompt: prompt, size: size, task: task)
        case .custom:
            return try await generateViaCustomProvider(prompt: prompt, size: size)
        }
        #else
        // iOS is subscription-only: image generation always goes through
        // the cutti relay. The BYOK code path is compiled out.
        return try await generateViaCuttiRelay(prompt: prompt, size: size, task: task)
        #endif
    }

    // MARK: - Cutti Cloud path

    private func generateViaCuttiRelay(
        prompt: String,
        size: ImageGenerationSize,
        task: String? = nil
    ) async throws -> Data {
        // Outer loop allows a single transparent JWT rotation when the
        // first attempt 401s with an expired session token. The user
        // is signed in — their JWT just aged out — so rather than
        // surface "Please sign in from Settings.", we ask
        // RelaySession.rotate() for a fresh token and retry once.
        // Limited to one rotation per call to avoid loops.
        var didRotateJWT = false
        while true {
            let config = RelayClient.configurationFromDefaults()
            guard !config.relayBaseURL.isEmpty else {
                throw ImageGenerationError.relayNotConfigured
            }

            let base = config.relayBaseURL.hasSuffix("/")
                ? String(config.relayBaseURL.dropLast())
                : config.relayBaseURL
            guard let url = URL(string: "\(base)/v1/images/generations") else {
                throw ImageGenerationError.relayNotConfigured
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Match OpenAIClient's jwt:/dev: prefix convention so we never
            // diverge on what header gets set. Kept inline here (instead of
            // factored out) to avoid coupling ImageGenerationService back
            // into OpenAIClient's type.
            let token = config.apiKey
            if token.hasPrefix("jwt:") {
                request.setValue("Bearer \(String(token.dropFirst(4)))", forHTTPHeaderField: "Authorization")
            } else if token.hasPrefix("dev:") {
                request.setValue(String(token.dropFirst(4)), forHTTPHeaderField: "X-Cutti-Dev-Token")
            } else if !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-Cutti-Dev-Token")
            }

            let body: [String: Any] = {
                var b: [String: Any] = [
                    "prompt": prompt,
                    // Send the abstract aspect; the relay owns the mapping to
                    // whatever actual pixel dimensions the current upstream
                    // model supports. Do NOT send width/height — old shipped
                    // .app builds that hardcoded pixel values is exactly what
                    // this refactor avoids.
                    "aspect": size.rawValue,
                ]
                if let tag = task, !tag.isEmpty {
                    // Per-feature attribution. Validated against an allowlist
                    // regex on the relay; older backends ignore unknown keys
                    // so this is safe to send unconditionally.
                    b["task"] = tag
                }
                return b
            }()
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 120

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw ImageGenerationError.fileIOFailed(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ImageGenerationError.invalidResponse
            }

            // Forward credit headers to the rest of the app so the quota UI
            // updates without waiting for /v1/me. Same behavior as OpenAIClient.
            RelayCreditsNotification.postIfPresent(from: http)

            if http.statusCode == 200 {
                return try Self.decodeOpenAIShapeImageResponse(data)
            }

            // 401 from the cuttiCloud relay → try a one-shot JWT
            // rotation before giving up. Mirrors OpenAIClient's
            // chatCompletion auto-rotate path.
            if !didRotateJWT,
               http.statusCode == 401,
               token.hasPrefix("jwt:") {
                didRotateJWT = true
                if await OpenAIClient.attemptRelayJWTRotation() {
                    continue
                }
            }

            // Map the relay's typed error envelope (quota_exceeded /
            // email_not_verified / unauthorized) to a friendly
            // localized message. We DELIBERATELY never embed the raw
            // response body in user-facing strings — the JSON contains
            // internal fields like `credits_used` / `worst_case_cost`
            // that are dev-only diagnostics, not UI copy.
            if let mapped = OpenAIClient.parseRelayError(
                statusCode: http.statusCode,
                data: data
            ) {
                throw ImageGenerationError.relayMessage(mapped.displayMessage)
            }
            throw ImageGenerationError.relayMessage(
                L("Image generation is temporarily unavailable. Please try again in a moment.")
            )
        }
    }

    // MARK: - Custom (BYOK) path

    #if os(macOS)
    /// macOS-only: iOS is subscription-only and cannot reach this path
    /// (the dispatch in `generate()` doesn't compile the BYOK arm on
    /// iOS), so the entire custom-provider implementation — which
    /// reads `CuttiSettings.customAIConfiguration()` from
    /// macOS-only AppStorage + keychain — is compiled out on iOS.
    private func generateViaCustomProvider(
        prompt: String,
        size: ImageGenerationSize
    ) async throws -> Data {
        let custom = CuttiSettings.customAIConfiguration()
        guard custom.hasUsableImageConfig else {
            throw ImageGenerationError.relayNotConfigured
        }

        let baseRaw = custom.effectiveImageBaseURL
        let base = baseRaw.hasSuffix("/") ? String(baseRaw.dropLast()) : baseRaw
        // OpenAI shape: `<base>/images/generations` where `<base>`
        // already contains `/v1` (e.g. `https://api.openai.com/v1`).
        guard let url = URL(string: "\(base)/images/generations") else {
            throw ImageGenerationError.relayNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(custom.effectiveImageApiKey)", forHTTPHeaderField: "Authorization")

        // OpenAI image-gen wire format. We translate Cutti's abstract
        // aspect into the closest size string that recent OpenAI image
        // models accept across families (DALL-E 3, gpt-image-1).
        let openAISize: String = {
            switch size {
            case .square:    return "1024x1024"
            case .portrait:  return "1024x1792"
            case .landscape: return "1792x1024"
            }
        }()
        let body: [String: Any] = [
            "model": custom.effectiveImageModel,
            "prompt": prompt,
            "size": openAISize,
            "n": 1,
            "response_format": "b64_json",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ImageGenerationError.fileIOFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw ImageGenerationError.relayError(status: http.statusCode, body: text)
        }

        return try Self.decodeOpenAIShapeImageResponse(data)
    }
    #endif

    /// Both the cutti relay and any OpenAI-compatible provider return
    /// the same `{ "data": [{ "b64_json": "..." }] }` shape. Centralised
    /// here so the two call paths can't drift on parsing.
    private static func decodeOpenAIShapeImageResponse(_ data: Data) throws -> Data {
        struct ImageResponse: Decodable {
            struct Entry: Decodable {
                let b64_json: String
            }
            let data: [Entry]
        }

        let decoded: ImageResponse
        do {
            decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
        } catch {
            throw ImageGenerationError.invalidResponse
        }

        guard let first = decoded.data.first,
              let png = Data(base64Encoded: first.b64_json) else {
            throw ImageGenerationError.noImagesReturned
        }

        return png
    }
}

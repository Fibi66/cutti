import Foundation

/// Errors surfaced by `ImageGenerationService`. The `.relayError` case
/// carries the HTTP status + a truncated body so callers can turn
/// 402/403/503 into specific user-facing messages (quota / email
/// verification / provider not configured) without re-parsing the body.
enum ImageGenerationError: Error, LocalizedError {
    case relayNotConfigured
    case invalidResponse
    case relayError(status: Int, body: String)
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
    func generate(
        prompt: String,
        size: ImageGenerationSize = .square1024
    ) async throws -> Data {
        // `configurationFromDefaults()` is now safe to call from any
        // actor — credentials live in a lock-protected snapshot — so we
        // no longer need to bounce through `MainActor.run` here. The
        // relay is the only configuration this code path ever produces,
        // so a provider check would be dead weight.
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

        let body: [String: Any] = [
            "prompt": prompt,
            // Send the abstract aspect; the relay owns the mapping to
            // whatever actual pixel dimensions the current upstream
            // model supports. Do NOT send width/height — old shipped
            // .app builds that hardcoded pixel values is exactly what
            // this refactor avoids.
            "aspect": size.rawValue,
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

        // Forward credit headers to the rest of the app so the quota UI
        // updates without waiting for /v1/me. Same behavior as OpenAIClient.
        RelayCreditsNotification.postIfPresent(from: http)

        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw ImageGenerationError.relayError(status: http.statusCode, body: text)
        }

        struct RelayImageResponse: Decodable {
            struct Entry: Decodable {
                let b64_json: String
            }
            let data: [Entry]
        }

        let decoded: RelayImageResponse
        do {
            decoded = try JSONDecoder().decode(RelayImageResponse.self, from: data)
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

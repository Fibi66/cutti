import Foundation

/// `RemotionOverlayRendering` implementation that renders overlays on
/// Azure Container Apps via the Cutti relay instead of shelling out
/// to `npx remotion render` locally.
///
/// The flow:
///   1. POST `/v1/render/overlay` on the relay with the render request
///      (JWT-authenticated, credits-metered).
///   2. Relay forwards to the Azure Container App running the Remotion
///      docker image (see `remotion/Dockerfile`), which renders the
///      composition, uploads the `.mov` to Azure Blob Storage, and
///      returns a short-lived signed read URL.
///   3. We download the mov to `outputURL` so the rest of the overlay
///      pipeline (content-addressable cache, MediaCore import, timeline
///      insertion) is unchanged.
///
/// The `LocalRemotionRenderer` stays as the fallback for offline /
/// developer builds; `ContentView` picks between them at VM init time
/// based on whether `RelayClient` is configured.
struct CloudRemotionRenderer: RemotionOverlayRendering {
    /// Base URL of the Cutti relay, e.g. `https://api.cutti.app`.
    let relayBaseURL: URL
    /// Bearer token for the relay. Matches the `Authorization: Bearer`
    /// value used by chat: `"jwt:<session-jwt>"` or `"dev:<token>"`.
    let bearerToken: String
    /// Override for tests / dev proxies. Production uses `URLSession.shared`.
    var session: URLSession = .shared
    /// Tests inject a deterministic response decoder; production uses
    /// the standard JSONDecoder.
    var decoder: JSONDecoder = .init()

    private struct RenderResponse: Decodable {
        let downloadURL: String
        let expiresAt: Int?
        let credits: RenderCredits?

        enum CodingKeys: String, CodingKey {
            case downloadURL = "download_url"
            case expiresAt = "expires_at"
            case credits
        }
    }

    private struct RenderCredits: Decodable {
        let charged: Int?
        let remaining: Int?
    }

    func render(_ request: RemotionRenderRequest, outputURL: URL) async throws {
        let endpoint = relayBaseURL.appendingPathComponent("v1/render/overlay")
        print("🎬 [overlay] CloudRemotionRenderer POST \(endpoint.absoluteString) template=\(request.templateID) duration=\(request.durationSeconds)s \(request.width)x\(request.height)@\(request.fps)fps tokenPrefix=\(bearerToken.prefix(4))")
        // The relay is a synchronous proxy: it waits for the Azure
        // Container App to run `remotion render` + upload to blob
        // before responding. A 6–15s ProRes 4444 @ 1080×1920 can
        // reasonably take 60–180s end-to-end depending on template
        // complexity and container cold-start, so we cannot rely on
        // `URLSession.shared`'s 60s default request timeout — it
        // surfaces as "The request timed out" after exactly 60s with
        // the render still in flight server-side.
        var req = URLRequest(url: endpoint, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Mirror OpenAIClient / ImageGenerationService: the token comes
        // in tagged with a `jwt:` or `dev:` prefix that selects which
        // header the relay expects. Sending the prefix verbatim as
        // `Bearer jwt:<token>` makes the relay try to verify the
        // literal string `jwt:<token>` as a JWT and bail out with a
        // 401 "bad signature".
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

        var body: [String: Any] = [
            "template_id": request.templateID,
            "props_json": request.propsJSON,
            "duration_seconds": request.durationSeconds,
            "width": request.width,
            "height": request.height,
            "fps": request.fps,
        ]
        if let tag = request.task, !tag.isEmpty {
            // Per-feature attribution. The relay validates this against
            // an allowlist regex; unknown values are silently dropped
            // server-side, so sending it here is safe even on older
            // backends that ignore it.
            body["task"] = tag
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            print("🎬 [overlay] CloudRemotionRenderer: non-HTTP response")
            throw RemotionRenderError.launchFailed("Invalid response from relay (not HTTP).")
        }
        print("🎬 [overlay] CloudRemotionRenderer response status=\(http.statusCode) bytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
            print("🎬 [overlay] CloudRemotionRenderer error body (≤512B): \(String(data: data.prefix(512), encoding: .utf8) ?? "<binary>")")
            // Map the relay's typed error envelope (quota_exceeded /
            // email_not_verified / unauthorized) to a friendly localized
            // message. We DELIBERATELY never embed the raw response body
            // in user-facing strings — the JSON contains internal fields
            // like `credits_used` / `worst_case_cost` that are dev-only
            // diagnostics, not UI copy.
            if let mapped = OpenAIClient.parseRelayError(
                statusCode: http.statusCode,
                data: data
            ) {
                throw RemotionRenderError.relayMessage(mapped.displayMessage)
            }
            throw RemotionRenderError.relayMessage(
                L("Animation rendering is temporarily unavailable. Please try again in a moment.")
            )
        }

        let decoded: RenderResponse
        do {
            decoded = try decoder.decode(RenderResponse.self, from: data)
        } catch {
            throw RemotionRenderError.launchFailed(
                "Relay response malformed: \(error.localizedDescription)"
            )
        }
        guard let blobURL = URL(string: decoded.downloadURL) else {
            throw RemotionRenderError.launchFailed(
                "Relay returned invalid download_url: \(decoded.downloadURL)"
            )
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Stream the rendered mov from Azure Blob Storage to disk. We
        // use `data(for:)` for simplicity; swap in `download(for:)` and
        // `FileManager.moveItem` if overlay renders routinely exceed a
        // few hundred MB. Apply the same extended timeout — a 15s
        // ProRes 4444 can be ~60 MB and over a slow connection a 60s
        // default is tight.
        var blobReq = URLRequest(url: blobURL, timeoutInterval: 300)
        let (blobData, blobResponse) = try await session.data(for: blobReq)
        guard let blobHTTP = blobResponse as? HTTPURLResponse,
              (200..<300).contains(blobHTTP.statusCode) else {
            throw RemotionRenderError.launchFailed(
                "Failed to download rendered mov from Azure Blob Storage."
            )
        }
        try blobData.write(to: outputURL, options: .atomic)
    }
}

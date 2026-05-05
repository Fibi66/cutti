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
        // Outer loop: a single transparent JWT rotation when the
        // captured bearerToken has aged out since this renderer was
        // constructed. The relay returns 401 with reason="expired";
        // rather than surface that to the user (who IS signed in), we
        // ask RelaySession for a fresh JWT and retry once. Capped at
        // one rotation per render to avoid loops.
        var didRotateJWT = false
        // Live token: starts at the constructor-captured value, and on
        // a successful rotation gets replaced with the freshly-issued
        // JWT pulled from RelaySession's snapshot. The captured value
        // is kept as the seed because tests inject a fixed bearer
        // through `init` and don't have a RelaySession populated.
        var liveToken = bearerToken
        while true {
            print("🎬 [overlay] CloudRemotionRenderer POST \(endpoint.absoluteString) template=\(request.templateID) duration=\(request.durationSeconds)s \(request.width)x\(request.height)@\(request.fps)fps tokenPrefix=\(liveToken.prefix(4))")
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
            if liveToken.hasPrefix("jwt:") {
                req.setValue(
                    "Bearer \(String(liveToken.dropFirst(4)))",
                    forHTTPHeaderField: "Authorization"
                )
            } else if liveToken.hasPrefix("dev:") {
                req.setValue(
                    String(liveToken.dropFirst(4)),
                    forHTTPHeaderField: "X-Cutti-Dev-Token"
                )
            } else if !liveToken.isEmpty {
                req.setValue(liveToken, forHTTPHeaderField: "X-Cutti-Dev-Token")
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
            if (200..<300).contains(http.statusCode) {
                let decoded: RenderResponse
                do {
                    decoded = try decoder.decode(RenderResponse.self, from: data)
                } catch {
                    print("🎬 [overlay] CloudRemotionRenderer decode error: \(error.localizedDescription)")
                    throw RemotionRenderError.launchFailed("Could not decode relay response: \(error.localizedDescription)")
                }
                try await downloadResult(decoded: decoded, outputURL: outputURL)
                return
            }
            print("🎬 [overlay] CloudRemotionRenderer error body (≤512B): \(String(data: data.prefix(512), encoding: .utf8) ?? "<binary>")")

            // 401 from the cuttiCloud relay → try a one-shot JWT
            // rotation before giving up. Mirrors OpenAIClient's
            // chatCompletion auto-rotate path. Only meaningful for
            // jwt: tokens — dev: tokens have no refresh endpoint.
            if !didRotateJWT,
               http.statusCode == 401,
               liveToken.hasPrefix("jwt:") {
                didRotateJWT = true
                if await OpenAIClient.attemptRelayJWTRotation() {
                    if let fresh = RelaySession.currentBearerToken(), !fresh.isEmpty {
                        liveToken = "jwt:\(fresh)"
                        continue
                    }
                }
            }

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
    }

    /// Downloads the rendered overlay from the short-lived signed URL
    /// the relay returns, and writes it to `outputURL`. Factored out
    /// of `render()` so the success path stays readable inside the
    /// rotate-on-401 outer loop.
    private func downloadResult(decoded: RenderResponse, outputURL: URL) async throws {
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
        let blobReq = URLRequest(url: blobURL, timeoutInterval: 300)
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

import Foundation
import CuttiKit

/// Thin, serialised HTTP client for the local Qwen3-ASR sidecar.
///
/// The sidecar's `Qwen3ASRModel` is configured with
/// `max_inference_batch_size=1`, so concurrent calls don't actually
/// run in parallel — they queue inside python, and a second caller
/// just adds latency without any throughput win. We therefore serialise
/// at the actor boundary so the Swift side has a clean view of "this
/// call is in flight" for cancel / progress reporting.
///
/// All HTTP I/O happens against `127.0.0.1` only — the sidecar binds
/// to the loopback interface, so an attacker on the local network can
/// never see this traffic. Auth still lives in an Authorization
/// header to defend against other local processes (other users on a
/// shared Mac, malicious local daemons, etc.).
actor QwenAsrSidecarClient {

    static let shared = QwenAsrSidecarClient()

    /// Long-running request: 20 minutes upper bound covers a 60-min
    /// long-form file at the observed ~0.4 RTF on M-series (24 min
    /// wall) plus ~10% slack. Anything longer than that we'd want to
    /// chunk on the cutti side anyway.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20 * 60
        cfg.timeoutIntervalForResource = 25 * 60
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// One-shot transcription request. Maps the sidecar's per-token
    /// items into `TranscriptSegment`s using the same shape as the
    /// Apple-Speech path so downstream cue-builder code is
    /// backend-agnostic.
    ///
    /// The `language` parameter accepts the Qwen aligner names
    /// ("Chinese", "Cantonese", "English", …). When unsupported the
    /// sidecar will still return text but with empty `items`; we
    /// detect that and fall back to a single sentence-level segment
    /// so the caller never sees a totally-empty result for a non-
    /// empty audio file.
    func transcribe(
        audioPath: String,
        language: String?,
        context: String? = nil
    ) async throws -> Result {
        let (port, token) = try await QwenAsrSidecarManager.shared.ensureRunning()

        guard let url = URL(string: "http://127.0.0.1:\(port)/transcribe") else {
            throw QwenAsrSidecarError.sidecarSpawnFailed("invalid sidecar port")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = TranscribeRequest(
            path: audioPath,
            language: language,
            return_time_stamps: true,
            context: context ?? ""
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QwenAsrSidecarError.sidecarReturnedError(status: -1, body: "no HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw QwenAsrSidecarError.sidecarReturnedError(status: http.statusCode, body: bodyStr)
        }

        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)

        return Self.mapResponse(decoded)
    }

    /// Snapshot of the sidecar's current /transcribe stage. Returned
    /// by `/progress`; `nil` if the sidecar isn't reachable or the
    /// poll fails (the caller treats absence as "no update").
    struct ProgressSnapshot: Sendable, Decodable {
        let stage: String
        let chunkIndex: Int
        let chunkTotal: Int
        let elapsedSec: Double

        enum CodingKeys: String, CodingKey {
            case stage
            case chunkIndex = "chunk_index"
            case chunkTotal = "chunk_total"
            case elapsedSec = "elapsed_sec"
        }
    }

    /// Poll the sidecar's /progress endpoint for the current
    /// transcribe-call stage. Returns `nil` on any failure (sidecar
    /// not running, network error, decode error) so callers can
    /// treat it as a best-effort hint rather than an authoritative
    /// state machine.
    func fetchProgress() async -> ProgressSnapshot? {
        guard let (port, token) = try? await QwenAsrSidecarManager.shared.ensureRunning() else {
            return nil
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/progress") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 2.0
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(ProgressSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - DTOs

    struct Result: Sendable {
        /// Sentence/full-text representation. Single segment because
        /// the sidecar returns one big `text` blob covering the whole
        /// audio. The cue builder never uses this for timing; only
        /// for "did the model produce anything at all" sanity checks.
        let displaySegments: [TranscriptSegment]
        /// Per-token timings (per-character for CJK, per-word for
        /// space-delimited Latin / Korean / etc.). This is the field
        /// downstream subtitle-cue code consumes.
        let wordSegments: [TranscriptSegment]
        let language: String?
        let realTimeFactor: Double?
    }

    private struct TranscribeRequest: Encodable {
        let path: String
        let language: String?
        let return_time_stamps: Bool
        let context: String
    }

    private struct TranscribeResponse: Decodable {
        let text: String
        let language: String?
        let items: [Item]
        let elapsed_sec: Double?
        let audio_duration_sec: Double?
        let real_time_factor: Double?
        let asr_model: String?
        let aligner_model: String?

        struct Item: Decodable {
            let text: String
            let start_sec: Double?
            let end_sec: Double?
        }
    }

    private static func mapResponse(_ resp: TranscribeResponse) -> Result {
        // Per-token segments. We drop items missing either timestamp
        // (the aligner can return half-aligned tokens at chunk
        // boundaries on very long files) instead of synthesising a
        // fake duration — the cue builder is robust to gaps but
        // would mis-align if we faked the timing.
        //
        // Note: Qwen's ForcedAligner emits one entry per audio-bearing
        // character. Punctuation (`。！？，；…` quotes/parens) is NOT
        // present here because it carries no audio. We deliberately
        // do not try to repair punctuation: the downstream cue
        // builder segments on inter-character silence gaps, which is
        // more robust than reasoning about punctuation.
        var word: [TranscriptSegment] = []
        word.reserveCapacity(resp.items.count)
        for item in resp.items {
            guard let start = item.start_sec, let end = item.end_sec else { continue }
            guard end > start else { continue }
            let cleaned = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            word.append(TranscriptSegment(
                startSeconds: start,
                endSeconds: end,
                text: cleaned
            ))
        }

        var display: [TranscriptSegment] = []
        let trimmedText = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            // Approximate the full-clip span from the first/last
            // aligned items so the display segment has sensible
            // bounds when paired with the per-token list. If the
            // aligner returned nothing (unsupported language path),
            // start at 0 and let the caller pad as needed.
            let start = word.first?.startSeconds ?? 0
            let end = word.last?.endSeconds ?? max(start + 0.01, start)
            display.append(TranscriptSegment(
                startSeconds: start,
                endSeconds: end,
                text: trimmedText
            ))
        }

        return Result(
            displaySegments: display,
            wordSegments: word,
            language: resp.language,
            realTimeFactor: resp.real_time_factor
        )
    }
}

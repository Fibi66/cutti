import Foundation
import CuttiKit

/// Minimal OpenAI-driven subtitle translator used by the iOS
/// `subtitle.*` AI presets. Mirrors the batching strategy in macOS
/// `AgentTranslateSubtitlesTool` but is stripped of all agent-tool
/// ceremony (argument parsing, tool schema, force/idempotence flags)
/// because the iOS preset entry points always want "translate every
/// cue to <locale>, overwrite if present" semantics.
///
/// The translator itself is pure-function: it only produces a
/// `[cueID: translatedText]` map. Applying those translations onto
/// `ProjectDocument` is the caller's responsibility so each preset
/// can decide whether to also flip `transcriptDisplayLocale` for
/// bilingual display.
enum SubtitleTranslator {
    /// Maximum number of cues sent to the model in a single chat
    /// completion. Matches macOS's default batch size — ~20 short
    /// cues fit comfortably inside a single response and keep
    /// latency predictable when the transcript is long.
    private static let batchSize = 20

    struct Input: Hashable, Sendable {
        let id: UUID
        let text: String
    }

    enum Error: LocalizedError {
        case notSignedIn
        case emptyReply
        case parseFailed(String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return L("请先登录账号")
            case .emptyReply:
                return L("AI 返回为空")
            case .parseFailed(let detail):
                return L("解析翻译结果失败：") + detail
            case .underlying(let detail):
                return detail
            }
        }
    }

    /// Translate every non-empty cue text to `targetLocale` using the
    /// cloud relay. Returns a dictionary keyed by the original cue
    /// id so the caller can map it back onto `SubtitleEntry`.
    static func translate(
        cues: [Input],
        targetLocale: String
    ) async throws -> [UUID: String] {
        guard !cues.isEmpty else { return [:] }

        let token = RelaySession.currentBearerToken() ?? ""
        guard !token.isEmpty else { throw Error.notSignedIn }

        let config = OpenAIConfiguration.fromEnvironment()
            ?? RelayClient.configurationFromDefaults()
        let client = OpenAIClient(configuration: config)

        var aggregated: [UUID: String] = [:]
        let batches = stride(from: 0, to: cues.count, by: batchSize).map {
            Array(cues[$0..<min($0 + batchSize, cues.count)])
        }

        for batch in batches {
            let translations = try await runOneBatch(
                batch: batch,
                locale: targetLocale,
                client: client
            )
            for (id, text) in translations {
                aggregated[id] = text
            }
        }
        return aggregated
    }

    // MARK: - Single batch round-trip

    private static func runOneBatch(
        batch: [Input],
        locale: String,
        client: OpenAIClient
    ) async throws -> [UUID: String] {
        let systemPrompt = """
        You are a professional subtitle translator. Translate each cue into \
        the target locale preserving tone, register, punctuation style, and \
        any placeholders verbatim. Do not summarize, shorten, or \
        re-segment the cues. Return ONE JSON object whose keys are the \
        cue UUIDs and whose values are the translated strings. No prose, no \
        code fences, no trailing explanation.
        Target locale (BCP-47): \(locale)
        """

        var lines: [String] = []
        for cue in batch {
            let escaped = cue.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("  \"\(cue.id.uuidString)\": \"\(escaped)\"")
        }
        let userContent = "{\n" + lines.joined(separator: ",\n") + "\n}"

        let messages: [ChatMessage] = [
            .system(systemPrompt),
            .user(userContent),
        ]

        for attempt in 0..<2 {
            do {
                let response = try await client.chatCompletion(
                    messages: messages,
                    temperature: 0.2
                )
                let raw = (response.content ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { throw Error.emptyReply }
                if let parsed = parseResponse(raw, expected: batch) {
                    return parsed
                }
                if attempt == 1 {
                    throw Error.parseFailed(L("AI 回复不是预期的 JSON 格式"))
                }
            } catch {
                if attempt == 1 { throw Error.underlying(error.localizedDescription) }
            }
        }
        return [:]
    }

    /// Tolerant JSON parser — strips a leading/trailing markdown code
    /// fence if the model adds one and accepts any subset of expected
    /// cue ids. Returns nil when the reply can't be coerced into a
    /// `[UUID: String]` map so the caller can retry once.
    private static func parseResponse(
        _ raw: String,
        expected: [Input]
    ) -> [UUID: String]? {
        var body = raw
        if body.hasPrefix("```") {
            // Drop leading fence line (```json) and trailing fence.
            if let firstNewline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: firstNewline)...])
            }
            if let range = body.range(of: "```", options: .backwards) {
                body = String(body[..<range.lowerBound])
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = body.data(using: .utf8) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let expectedIDs = Set(expected.map { $0.id })
        var out: [UUID: String] = [:]
        for (key, value) in dict {
            guard let id = UUID(uuidString: key), expectedIDs.contains(id) else { continue }
            if let s = value as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out[id] = trimmed }
            }
        }
        return out.isEmpty ? nil : out
    }
}

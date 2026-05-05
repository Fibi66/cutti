import Foundation

/// Cleans the local-ASR transcript for the AI chat composer. Currently removes
/// common English + Chinese filler words so the user doesn't have to
/// manually delete "um", "uh", "嗯", "额", "那个", etc. before sending.
///
/// Ported from Veery's `corrector.py` (`_EN_FILLERS` / `_ZH_FILLERS`).
/// Intentionally conservative — we only strip tokens that are almost
/// never load-bearing in chat prompts.
enum TranscriptCleaner {
    /// English fillers. Word-boundary-anchored so we don't eat letters
    /// out of real words (e.g. "umbrella", "human").
    private static let englishFillers: [String] = [
        #"\bum\b"#, #"\buh\b"#, #"\bumm\b"#, #"\buhh\b"#,
        #"\byou know\b"#, #"\bI mean\b"#,
        #"\bbasically\b"#, #"\bliterally\b"#,
    ]

    /// Chinese fillers. CJK text has no word boundaries, so these match
    /// anywhere — same trade-off Veery accepts. Keep this list tight.
    private static let chineseFillers: [String] = [
        "嗯", "额", "呃",
        "那个", "就是说", "然后吧",
    ]

    private static let fillerRegex: NSRegularExpression = {
        let escaped = chineseFillers.map { NSRegularExpression.escapedPattern(for: $0) }
        // (filler_alternation) + optional trailing punctuation + any
        // trailing whitespace. Eating the trailing comma/period inline
        // prevents leftovers like ", please" or "this ,, section" when
        // the filler sits right next to punctuation.
        let pattern = #"(?:"# + (englishFillers + escaped).joined(separator: "|") + #")[,.!?;:，。！？；：、]?\s*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let multiSpaceRegex = try! NSRegularExpression(pattern: "  +")

    /// Whitespace that was left directly in front of a punctuation mark
    /// after removing a filler — e.g. "Hello , world" → "Hello, world".
    /// Covers both ASCII and CJK punctuation so both "hello ." and
    /// "你好 ，" read naturally after cleanup.
    private static let spaceBeforePunctRegex = try! NSRegularExpression(
        pattern: #"\s+([,.!?;:，。！？；：、])"#
    )

    /// Strip fillers and tidy the resulting whitespace. Returns the
    /// original string unchanged when nothing matches.
    static func stripFillers(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        var range = NSRange(location: 0, length: mutable.length)
        fillerRegex.replaceMatches(in: mutable, options: [], range: range, withTemplate: "")

        range = NSRange(location: 0, length: mutable.length)
        spaceBeforePunctRegex.replaceMatches(in: mutable, options: [], range: range, withTemplate: "$1")

        range = NSRange(location: 0, length: mutable.length)
        multiSpaceRegex.replaceMatches(in: mutable, options: [], range: range, withTemplate: " ")

        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

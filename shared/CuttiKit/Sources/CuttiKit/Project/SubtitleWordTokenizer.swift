import Foundation

/// Splits a subtitle cue's plain text into selectable tokens that the
/// emphasis UI can show as individual tap targets. Each token carries
/// the UTF-16 range it occupies in the cue — the same offset space
/// `SubtitleRunEditor.applyStyle(...)` operates on, so callers can
/// feed ranges straight through without conversion.
///
/// Tokenization rules (v1):
///   - Whitespace characters (space, tab, newline) are **separators**
///     and never appear in a token themselves.
///   - Any run of latin/latin-extended/digit/punctuation characters
///     between whitespace breaks forms one token ("hello," "1.5x"
///     are each one token).
///   - CJK Unified Ideographs are emitted **one character per token**
///     because Chinese users typically emphasize individual characters
///     or short phrases, and words in CJK aren't whitespace-delimited.
///   - Empty input produces an empty array, not a single zero-length
///     token.
public enum SubtitleWordTokenizer {

    public struct Token: Equatable, Sendable {
        /// The substring this token covers. Same content as what's in
        /// `text` at `utf16Range`.
        public let text: String
        /// UTF-16 offset + length into the source cue string.
        public let utf16Range: NSRange

        public init(text: String, utf16Range: NSRange) {
            self.text = text
            self.utf16Range = utf16Range
        }
    }

    /// Tokenize `text` into user-selectable units.
    public static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        var bufferUTF16Start = 0
        var cursor = 0  // running UTF-16 offset

        func flush() {
            if !buffer.isEmpty {
                let len = (buffer as NSString).length
                tokens.append(Token(
                    text: buffer,
                    utf16Range: NSRange(location: bufferUTF16Start, length: len)
                ))
                buffer = ""
            }
        }

        for scalar in text.unicodeScalars {
            let unitLen = scalar.utf16.count  // 1 for BMP, 2 for surrogate pair
            if scalar.properties.isWhitespace || isLineBreak(scalar) {
                flush()
                cursor += unitLen
                bufferUTF16Start = cursor
            } else if isCJKIdeograph(scalar) {
                // CJK char is its own token — flush anything buffered
                // before it, emit it, advance.
                flush()
                let glyph = String(scalar)
                tokens.append(Token(
                    text: glyph,
                    utf16Range: NSRange(location: cursor, length: unitLen)
                ))
                cursor += unitLen
                bufferUTF16Start = cursor
            } else {
                if buffer.isEmpty {
                    bufferUTF16Start = cursor
                }
                buffer.unicodeScalars.append(scalar)
                cursor += unitLen
            }
        }
        flush()
        return tokens
    }

    /// Merge adjacent selected tokens into minimal `[NSRange]` so that
    /// `SubtitleRunEditor.setStyle` is called once per contiguous
    /// selection instead of once per individual token (which would
    /// fragment the run array unnecessarily).
    public static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            let lastEnd = last.location + last.length
            if r.location <= lastEnd {
                let end = max(lastEnd, r.location + r.length)
                merged[merged.count - 1] = NSRange(
                    location: last.location, length: end - last.location)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    // MARK: - Character classifiers

    private static func isLineBreak(_ s: Unicode.Scalar) -> Bool {
        // Unicode newline class. `isWhitespace` covers \n but not all
        // line breaks; add explicit NEL / LINE SEPARATOR / PARAGRAPH
        // SEPARATOR to be safe.
        switch s.value {
        case 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// Roughly matches CJK Unified Ideographs + common extensions A/B
    /// and the CJK compatibility blocks. Kana (hiragana/katakana) is
    /// NOT included — Japanese users typically tokenize by word not
    /// character, so whitespace/punctuation breaks are closer to what
    /// they want. Extending later is non-breaking.
    private static func isCJKIdeograph(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)          // CJK Unified
            || (0x3400...0x4DBF).contains(v)          // Extension A
            || (0x20000...0x2A6DF).contains(v)        // Extension B
            || (0xF900...0xFAFF).contains(v)          // Compatibility
    }
}

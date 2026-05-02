import Foundation

/// Minimal SRT / WebVTT parser for the iOS transcript importer.
/// Pure string → cues; no I/O so it's unit-testable.
///
/// Accepts:
/// - SRT: optional numeric index line, then `HH:MM:SS,mmm --> HH:MM:SS,mmm`,
///   then one or more text lines, separated by a blank line.
/// - WebVTT: optional `WEBVTT` header + optional blank lines, then
///   `HH:MM:SS.mmm --> HH:MM:SS.mmm` (or `MM:SS.mmm`). Cue
///   identifiers and settings strings are tolerated and discarded.
enum SubtitleImporter {

    struct Cue: Equatable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
    }

    enum ParseError: LocalizedError {
        case empty
        case noCues

        var errorDescription: String? {
            switch self {
            case .empty:  return "文件为空"
            case .noCues: return "没有识别到任何字幕条目"
            }
        }
    }

    /// Parse either SRT or WebVTT. Format is auto-detected by the
    /// `WEBVTT` header and timestamp separator.
    static func parse(_ body: String) throws -> [Cue] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        // Normalize line endings.
        let normalized = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Drop the VTT header + any NOTE/STYLE/REGION blocks.
        var lines = normalized.components(separatedBy: "\n")
        if lines.first?.uppercased().hasPrefix("WEBVTT") == true {
            lines.removeFirst()
        }

        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            // Skip blanks.
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            }
            guard i < lines.count else { break }

            // Skip VTT metadata blocks.
            let head = lines[i].trimmingCharacters(in: .whitespaces).uppercased()
            if head.hasPrefix("NOTE") || head.hasPrefix("STYLE") || head.hasPrefix("REGION") {
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }

            // If this line does not contain `-->` treat it as an
            // optional cue index / identifier and advance.
            var arrowLine = lines[i]
            if !arrowLine.contains("-->") {
                i += 1
                guard i < lines.count else { break }
                arrowLine = lines[i]
                // Not a timestamp line either → bail out on this block.
                if !arrowLine.contains("-->") { continue }
            }
            guard let (start, end) = parseArrowLine(arrowLine) else {
                i += 1
                continue
            }
            i += 1

            // Collect text lines until a blank or EOF.
            var textLines: [String] = []
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[i])
                i += 1
            }
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, end > start else { continue }
            cues.append(Cue(startSeconds: start, endSeconds: end, text: text))
        }

        guard !cues.isEmpty else { throw ParseError.noCues }
        return cues
    }

    // MARK: - Helpers

    private static func parseArrowLine(_ line: String) -> (Double, Double)? {
        // `HH:MM:SS,mmm --> HH:MM:SS,mmm [settings]` or `...SS.mmm ...`.
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        // Drop optional WebVTT settings (`align:center`, …) on the right.
        let rightRaw = parts[1].trimmingCharacters(in: .whitespaces)
        let right = rightRaw
            .components(separatedBy: .whitespaces)
            .first ?? rightRaw
        guard let s = parseTimestamp(left),
              let e = parseTimestamp(right) else { return nil }
        return (s, e)
    }

    private static func parseTimestamp(_ s: String) -> Double? {
        // Accept `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS,mmm`, `MM:SS.mmm`.
        let norm = s.replacingOccurrences(of: ",", with: ".")
        let pieces = norm.split(separator: ":")
        guard pieces.count >= 2 else { return nil }
        let secondsComponent = String(pieces.last!)
        guard let seconds = Double(secondsComponent) else { return nil }
        var total = seconds
        if pieces.count >= 2 {
            let minutes = Double(pieces[pieces.count - 2]) ?? 0
            total += minutes * 60
        }
        if pieces.count >= 3 {
            let hours = Double(pieces[pieces.count - 3]) ?? 0
            total += hours * 3600
        }
        return total
    }
}

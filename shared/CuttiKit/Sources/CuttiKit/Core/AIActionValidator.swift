import Foundation

/// Pre-flight validator for `AIActionBatch`. Runs before
/// `AIActionExecutor.apply` so the Agent can hand structured error
/// messages back to the LLM when it proposes nonsense (unknown segment
/// IDs, times outside the timeline, invalid rates, …). The LLM then has
/// one more step in the loop to fix the call.
///
/// This validator is pure and additive — it never mutates state. The
/// executor is still the source of truth for "what actually applied"
/// because it handles edge-cases (e.g. splits that collapse into a
/// minimum duration) that we don't want to reimplement here.
public enum AIActionValidator {

    /// One structured issue flagged during pre-flight. Fed back to the
    /// LLM inside the tool result so it can correct on the next turn.
    public struct Issue: Codable, Equatable, Sendable {
        /// Zero-based index into `batch.actions` where the issue lives.
        public let actionIndex: Int
        /// Short machine-friendly code (e.g. "unknown_segment").
        public let code: String
        /// Human + LLM readable reason.
        public let message: String
    }

    public struct Report: Codable, Sendable {
        /// Issues severe enough that the action would definitely fail
        /// or be skipped by the executor. Blocks execution when any
        /// exists.
        public var errors: [Issue] = []
        /// Non-fatal concerns (e.g. clamped values, near-boundary
        /// durations) the LLM may want to consider.
        public var warnings: [Issue] = []

        public var hasErrors: Bool { !errors.isEmpty }
    }

    /// Validate every action in the batch against the current timeline
    /// snapshot. Unknown segment IDs, negative / inverted time ranges,
    /// and out-of-range speed rates are flagged as errors. Values that
    /// will be auto-clamped are flagged as warnings.
    ///
    /// `knownSourceVideoIDs` is consulted only by `insertSourceClip`,
    /// which references a foreign source recording the validator can't
    /// otherwise see. When non-empty, an unknown source UUID is flagged
    /// as an error so the LLM gets a structured retry path. Pass `[]`
    /// (the default) to skip the check, e.g. in unit tests that don't
    /// exercise the source-record indirection.
    public static func validate(
        batch: AIActionBatch,
        segments: [TimelineSegment],
        knownSourceVideoIDs: Set<UUID> = []
    ) -> Report {
        var report = Report()

        let segmentIDs = Set(segments.map(\.id))
        let totalDuration: Double = segments.reduce(0.0) { $0 + $1.durationSeconds }

        for (index, action) in batch.actions.enumerated() {
            switch action {
            case .deleteSegment(let id), .trimStart(let id, _), .trimEnd(let id, _),
                 .splitSegment(let id, _), .setVolume(let id, _), .setSpeed(let id, _):
                if !segmentIDs.contains(id) {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "unknown_segment",
                        message: "Segment id \(id.uuidString) is not in the current timeline. Call get_timeline_summary or get_segment_detail first."
                    ))
                }
                // Range / value checks
                switch action {
                case .trimStart(let id, let newStart), .trimEnd(let id, let newStart):
                    if let seg = segments.first(where: { $0.id == id }),
                       !(newStart > seg.range.startSeconds - 0.001 && newStart < seg.range.endSeconds + 0.001) {
                        report.errors.append(.init(
                            actionIndex: index,
                            code: "trim_out_of_bounds",
                            message: "Trim time \(newStart) is outside segment source range [\(seg.range.startSeconds), \(seg.range.endSeconds)]."
                        ))
                    }
                case .setVolume(_, let level):
                    if level < 0 || level > 4 {
                        report.errors.append(.init(
                            actionIndex: index,
                            code: "volume_out_of_range",
                            message: "Volume \(level) is outside [0, 4]. Use 1.0 for full volume, 0.0 to mute."
                        ))
                    } else if level > 2 {
                        report.warnings.append(.init(
                            actionIndex: index,
                            code: "volume_boosted",
                            message: "Volume > 2.0x may clip audio. Consider normalize_loudness."
                        ))
                    }
                case .setSpeed(_, let rate):
                    if rate <= 0 || rate > 8 {
                        report.errors.append(.init(
                            actionIndex: index,
                            code: "speed_out_of_range",
                            message: "Speed rate \(rate) must be in (0, 8]."
                        ))
                    }
                case .splitSegment(let id, let atSource):
                    if let seg = segments.first(where: { $0.id == id }) {
                        let minDur = 0.2
                        if atSource <= seg.range.startSeconds + minDur || atSource >= seg.range.endSeconds - minDur {
                            report.errors.append(.init(
                                actionIndex: index,
                                code: "split_too_close_to_edge",
                                message: "Split at \(atSource) leaves a sub-\(minDur)s fragment. Pick a time further from the segment edges."
                            ))
                        }
                    }
                default:
                    break
                }

            case .deleteRange(let start, let end), .setSpeedRange(let start, let end, _):
                if end <= start {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "inverted_range",
                        message: "Range end (\(end)) must be strictly greater than start (\(start))."
                    ))
                }
                if start < -0.001 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "negative_start",
                        message: "Range start (\(start)) must be >= 0."
                    ))
                }
                if start > totalDuration + 0.5 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "range_past_timeline",
                        message: "Range start (\(start)s) is past the end of the timeline (\(String(format: "%.2f", totalDuration))s)."
                    ))
                }
                if case .setSpeedRange(_, _, let rate) = action, rate <= 0 || rate > 8 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "speed_out_of_range",
                        message: "Speed rate \(rate) must be in (0, 8]."
                    ))
                }

            case .reorderSegments(let ids):
                if Set(ids) != segmentIDs {
                    let missing = segmentIDs.subtracting(ids).map { $0.uuidString }.sorted()
                    let extra = Set(ids).subtracting(segmentIDs).map { $0.uuidString }.sorted()
                    var parts: [String] = []
                    if !missing.isEmpty { parts.append("missing [\(missing.joined(separator: ", "))]") }
                    if !extra.isEmpty { parts.append("extra [\(extra.joined(separator: ", "))]") }
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "reorder_mismatch",
                        message: "reorderSegments must list every current segment id exactly once (\(parts.joined(separator: "; "))).")
                    )
                }

            case .insertSourceClip(let sourceVideoID, let sourceStart, let sourceEnd, let composedInsertAt, let fadeIn, let fadeOut):
                if sourceEnd <= sourceStart {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "inverted_source_range",
                        message: "Source range end (\(sourceEnd)) must be strictly greater than start (\(sourceStart))."
                    ))
                } else if sourceEnd - sourceStart < 0.2 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "source_range_too_short",
                        message: "Source range duration \(String(format: "%.3f", sourceEnd - sourceStart))s is below the 0.2s minimum. Pick a wider window."
                    ))
                }
                if composedInsertAt < -0.001 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "negative_composed_insert",
                        message: "composed_insert_at (\(composedInsertAt)) must be >= 0."
                    ))
                }
                if composedInsertAt > totalDuration + 0.5 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "insert_past_timeline",
                        message: "composed_insert_at (\(String(format: "%.2f", composedInsertAt))s) is past the end of the timeline (\(String(format: "%.2f", totalDuration))s). Use 0 to prepend or the timeline length to append."
                    ))
                }
                if fadeIn < 0 || fadeOut < 0 {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "negative_fade",
                        message: "Fade durations must be >= 0 (got fade_in \(fadeIn), fade_out \(fadeOut))."
                    ))
                }
                if !knownSourceVideoIDs.isEmpty && !knownSourceVideoIDs.contains(sourceVideoID) {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "unknown_source_video",
                        message: "source_video_id \(sourceVideoID.uuidString) is not in the project's media library. Only IDs surfaced by score_hook_candidates / get_timeline_summary are allowed."
                    ))
                }

            case .editSubtitle(let id, let atSeconds, let newText):
                if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "empty_subtitle_text",
                        message: "editSubtitle new_text cannot be empty."
                    ))
                }
                if id == nil && atSeconds == nil {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "missing_subtitle_target",
                        message: "editSubtitle requires either id or at_seconds."
                    ))
                }

            case .replaceSubtitleText(let find, _, _):
                if find.isEmpty {
                    report.errors.append(.init(
                        actionIndex: index,
                        code: "empty_find_pattern",
                        message: "replaceSubtitleText find pattern cannot be empty."
                    ))
                }

            case .setSubtitleStyle, .setSubtitlesVisible:
                break
            }
        }

        return report
    }
}

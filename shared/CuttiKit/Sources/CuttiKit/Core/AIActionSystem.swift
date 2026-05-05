import Foundation

// MARK: - AI Actions (UUID-targeted + composed-time range actions)

/// A single editing action. Simple direct edits still target a segment by UUID,
/// while timeline-wide commands can target a composed-time range in seconds.
public enum AIAction: Codable, Sendable {
    case deleteSegment(id: UUID)
    case deleteRange(start: Double, end: Double)
    case splitSegment(id: UUID, atSourceTime: Double)
    case trimStart(id: UUID, newStart: Double)
    case trimEnd(id: UUID, newEnd: Double)
    case setVolume(id: UUID, level: Double)
    case setSpeed(id: UUID, rate: Double)
    case setSpeedRange(start: Double, end: Double, rate: Double)
    case reorderSegments(ids: [UUID])
    /// Splice a slice of an arbitrary source recording into the current
    /// primary track at a composed-time anchor. Powers cold-open hook
    /// teasers, callbacks, and recap clips: the source clip can come
    /// from any media record (not just the ones already on the
    /// timeline). Inserting at composed time `0` prepends the slice
    /// before everything else; inserting between two segments cleanly
    /// pushes the rest of the timeline back. Inserting strictly inside
    /// a host segment splits the host and places the new clip between
    /// the two halves. Audio fades are applied via the new segment's
    /// `effects.audioFadeIn/OutDuration`. The action only mutates
    /// primary-track sequential placement (no `placementOffset`); the
    /// orchestrator that composes hook teasers (`add_hook_teaser`)
    /// owns higher-level concerns like duck-on-BGM and
    /// quote-card overlay.
    case insertSourceClip(
        sourceVideoID: UUID,
        sourceStart: Double,
        sourceEnd: Double,
        composedInsertAt: Double,
        fadeInSeconds: Double,
        fadeOutSeconds: Double
    )

    // MARK: Subtitle actions

    /// Replace the text of a single subtitle cue. Exactly one of `id` /
    /// `atSeconds` should be provided; `id` wins if both are set.
    case editSubtitle(id: UUID?, atSeconds: Double?, newText: String)
    /// Batch find-and-replace inside every subtitle cue. Case-sensitive unless
    /// `isRegex` is true and the pattern uses inline `(?i)` flags.
    case replaceSubtitleText(find: String, replaceWith: String, isRegex: Bool)
    /// Adjust any subset of the project-wide subtitle style. Fields not set in
    /// the patch are preserved.
    case setSubtitleStyle(patch: SubtitleStylePatch)
    /// Toggle the subtitle overlay on/off. Does not change burn-in settings.
    case setSubtitlesVisible(visible: Bool)
}

/// A batch of AI actions with an explanation, applied atomically.
public struct AIActionBatch: Codable, Sendable {
    public let actions: [AIAction]
    public let explanation: String

    public init(actions: [AIAction], explanation: String) {
        self.actions = actions
        self.explanation = explanation
    }

    public var userFacingSummary: String {
        let lines = actions.map { action -> String in
            switch action {
            case .deleteSegment:
                return "Delete a segment"
            case .deleteRange(let start, let end):
                return "Delete \(AIActionExecutor.formatTime(start))-\(AIActionExecutor.formatTime(end))"
            case .splitSegment:
                return "Split a segment"
            case .trimStart:
                return "Trim a segment start"
            case .trimEnd:
                return "Trim a segment end"
            case .setVolume(_, let level):
                return "Set volume to \(Int(level * 100))%"
            case .setSpeed(_, let rate):
                return "Set segment speed to \(AIActionExecutor.formatRate(rate))x"
            case .setSpeedRange(let start, let end, let rate):
                return "Set \(AIActionExecutor.formatTime(start))-\(AIActionExecutor.formatTime(end)) to \(AIActionExecutor.formatRate(rate))x"
            case .reorderSegments:
                return "Reorder segments"
            case .insertSourceClip(_, let sStart, let sEnd, let at, _, _):
                let duration = max(0, sEnd - sStart)
                return "Insert \(AIActionExecutor.formatTime(duration)) clip at \(AIActionExecutor.formatTime(at))"
            case .editSubtitle:
                return "Edit a subtitle"
            case .replaceSubtitleText(let find, let replaceWith, _):
                return "Replace subtitle text \"\(find)\" → \"\(replaceWith)\""
            case .setSubtitleStyle:
                return "Update subtitle style"
            case .setSubtitlesVisible(let visible):
                return visible ? "Show subtitles" : "Hide subtitles"
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - AI Action Executor

/// Applies an AIActionBatch to a frozen segment snapshot.
/// Range actions are resolved against the current composed timeline deterministically.
public struct AIActionExecutor {
    public typealias TranscriptLookup = ([TimeRange], UUID) -> [SubtitleEntry]

    public struct Result {
        public let segments: [TimelineSegment]
        public let appliedCount: Int
        public let skippedCount: Int
        /// Non-nil if one or more `setSubtitleStyle` actions were applied.
        /// Last-write-wins within a batch. The caller owns the live style
        /// state; the executor only reports what it would have become.
        public let subtitleStyle: SubtitleStyle?
        /// Non-nil if one or more `setSubtitlesVisible` actions were applied.
        public let showSubtitles: Bool?
        /// Human-readable diagnostics produced while applying the batch.
        /// Empty when every action either applied cleanly or was a
        /// no-op. Today this carries subtitle-style patch warnings (e.g.
        /// "bilingual enabled but no secondary locale") — the AI layer
        /// surfaces them back to the user so silent skips stay
        /// observable. Callers that don't care can ignore the list.
        public let warnings: [String]

        public init(
            segments: [TimelineSegment],
            appliedCount: Int,
            skippedCount: Int,
            subtitleStyle: SubtitleStyle?,
            showSubtitles: Bool?,
            warnings: [String] = []
        ) {
            self.segments = segments
            self.appliedCount = appliedCount
            self.skippedCount = skippedCount
            self.subtitleStyle = subtitleStyle
            self.showSubtitles = showSubtitles
            self.warnings = warnings
        }
    }

    private static let minimumSegmentDuration = 0.2

    /// Apply actions to a snapshot. Actions that reference missing IDs or invalid
    /// composed-time ranges are skipped.
    public static func apply(
        batch: AIActionBatch,
        to segments: [TimelineSegment],
        baseSubtitleStyle: SubtitleStyle = .default,
        transcriptLookup: TranscriptLookup
    ) -> Result {
        var segs = segments
        var applied = 0
        var skipped = 0
        var style: SubtitleStyle? = nil
        var visible: Bool? = nil
        var warnings: [String] = []

        for action in batch.actions {
            switch action {
            case .deleteSegment(let id):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    segs.remove(at: idx)
                    applied += 1
                } else {
                    skipped += 1
                }

            case .deleteRange(let start, let end):
                if let updated = deleteComposedRange(
                    range: TimeRange(startSeconds: start, endSeconds: end),
                    from: segs,
                    transcriptLookup: transcriptLookup
                ) {
                    segs = updated
                    applied += 1
                } else {
                    skipped += 1
                }

            case .splitSegment(let id, let atSourceTime):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    let original = segs[idx]
                    let splitTime = atSourceTime
                    guard splitTime > original.range.startSeconds + minimumSegmentDuration,
                          splitTime < original.range.endSeconds - minimumSegmentDuration else {
                        skipped += 1
                        continue
                    }

                    let leftRange = TimeRange(startSeconds: original.range.startSeconds, endSeconds: splitTime)
                    let rightRange = TimeRange(startSeconds: splitTime, endSeconds: original.range.endSeconds)

                    guard let left = makeDerivedSegment(
                        from: original,
                        range: leftRange,
                        transcriptLookup: transcriptLookup
                    ), let right = makeDerivedSegment(
                        from: original,
                        range: rightRange,
                        transcriptLookup: transcriptLookup
                    ) else {
                        skipped += 1
                        continue
                    }

                    segs.replaceSubrange(idx...idx, with: [left, right])
                    applied += 1
                } else {
                    skipped += 1
                }

            case .trimStart(let id, let newStart):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    let original = segs[idx]
                    let clamped = max(0, min(newStart, original.range.endSeconds - minimumSegmentDuration))
                    let updatedRange = TimeRange(startSeconds: clamped, endSeconds: original.range.endSeconds)
                    if let updated = makeDerivedSegment(
                        from: original,
                        id: original.id,
                        range: updatedRange,
                        transcriptLookup: transcriptLookup
                    ) {
                        segs[idx] = updated
                        applied += 1
                    } else {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }

            case .trimEnd(let id, let newEnd):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    let original = segs[idx]
                    let clamped = max(original.range.startSeconds + minimumSegmentDuration, newEnd)
                    let updatedRange = TimeRange(startSeconds: original.range.startSeconds, endSeconds: clamped)
                    if let updated = makeDerivedSegment(
                        from: original,
                        id: original.id,
                        range: updatedRange,
                        transcriptLookup: transcriptLookup
                    ) {
                        segs[idx] = updated
                        applied += 1
                    } else {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }

            case .setVolume(let id, let level):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    let clamped = max(0, min(1, level))
                    guard abs(segs[idx].volumeLevel - clamped) > 0.001 else {
                        skipped += 1
                        continue
                    }
                    segs[idx].volumeLevel = clamped
                    applied += 1
                } else {
                    skipped += 1
                }

            case .setSpeed(let id, let rate):
                if let idx = segs.firstIndex(where: { $0.id == id }) {
                    let clamped = clampRate(rate)
                    guard abs(segs[idx].normalizedSpeedRate - clamped) > 0.001 else {
                        skipped += 1
                        continue
                    }
                    segs[idx].speedRate = clamped
                    applied += 1
                } else {
                    skipped += 1
                }

            case .setSpeedRange(let start, let end, let rate):
                if let updated = setSpeedForComposedRange(
                    range: TimeRange(startSeconds: start, endSeconds: end),
                    rate: rate,
                    in: segs,
                    transcriptLookup: transcriptLookup
                ) {
                    segs = updated
                    applied += 1
                } else {
                    skipped += 1
                }

            case .reorderSegments(let ids):
                var reordered: [TimelineSegment] = []
                for id in ids {
                    if let seg = segs.first(where: { $0.id == id }) {
                        reordered.append(seg)
                    }
                }
                for seg in segs where !ids.contains(seg.id) {
                    reordered.append(seg)
                }
                segs = reordered
                applied += 1

            case .insertSourceClip(
                let sourceVideoID,
                let sourceStart,
                let sourceEnd,
                let composedInsertAt,
                let fadeIn,
                let fadeOut
            ):
                if let updated = insertSourceClip(
                    sourceVideoID: sourceVideoID,
                    sourceStart: sourceStart,
                    sourceEnd: sourceEnd,
                    composedInsertAt: composedInsertAt,
                    fadeInSeconds: fadeIn,
                    fadeOutSeconds: fadeOut,
                    in: segs,
                    transcriptLookup: transcriptLookup
                ) {
                    segs = updated
                    applied += 1
                } else {
                    skipped += 1
                }

            case .editSubtitle(let id, let atSeconds, let newText):
                let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { skipped += 1; continue }
                let targetID: UUID?
                if let id {
                    targetID = id
                } else if let atSeconds {
                    targetID = locateSubtitle(atComposedSeconds: atSeconds, in: segs)
                } else {
                    targetID = nil
                }
                guard let targetID,
                      let loc = findSubtitle(id: targetID, in: segs) else {
                    skipped += 1
                    continue
                }
                let old = segs[loc.segment].subtitles[loc.entry]
                guard old.text != trimmed else { skipped += 1; continue }
                segs[loc.segment].subtitles[loc.entry] = SubtitleEntry(
                    id: old.id,
                    relativeStart: old.relativeStart,
                    relativeDuration: old.relativeDuration,
                    text: trimmed,
                    speakerID: old.speakerID,
                    translations: old.translations,
                    runs: nil,
                    wordTimings: nil,
                    styleOverride: old.styleOverride
                )
                applied += 1

            case .replaceSubtitleText(let find, let replaceWith, let isRegex):
                guard !find.isEmpty else { skipped += 1; continue }
                let replacer = makeReplacer(find: find, replaceWith: replaceWith, isRegex: isRegex)
                guard let replacer else { skipped += 1; continue }
                var changed = 0
                for segIdx in segs.indices {
                    for subIdx in segs[segIdx].subtitles.indices {
                        let old = segs[segIdx].subtitles[subIdx]
                        let new = replacer(old.text)
                        if new != old.text {
                            segs[segIdx].subtitles[subIdx] = SubtitleEntry(
                                id: old.id,
                                relativeStart: old.relativeStart,
                                relativeDuration: old.relativeDuration,
                                text: new,
                                speakerID: old.speakerID,
                                translations: old.translations,
                                runs: nil,
                                wordTimings: nil,
                                styleOverride: old.styleOverride
                            )
                            changed += 1
                        }
                    }
                }
                if changed > 0 { applied += 1 } else { skipped += 1 }

            case .setSubtitleStyle(let patch):
                guard !patch.isEmpty else { skipped += 1; continue }
                let current = style ?? baseSubtitleStyle
                let report = patch.applyReporting(to: current)
                for w in report.warnings {
                    warnings.append(w.message)
                }
                let next = report.style
                guard next != current else { skipped += 1; continue }
                style = next
                applied += 1

            case .setSubtitlesVisible(let v):
                visible = v
                applied += 1
            }
        }

        return Result(
            segments: segs,
            appliedCount: applied,
            skippedCount: skipped,
            subtitleStyle: style,
            showSubtitles: visible,
            warnings: warnings
        )
    }

    public static func formatTime(_ seconds: Double) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let totalSeconds = totalMilliseconds / 1000
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1000

        if milliseconds == 0 {
            return String(format: "%d:%02d", minutes, secs)
        }
        return String(format: "%d:%02d.%03d", minutes, secs, milliseconds)
    }

    public static func formatRate(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.001 {
            return String(format: "%.0f", rate)
        }
        return String(format: "%.2f", rate)
    }

    private static func deleteComposedRange(
        range: TimeRange,
        from segments: [TimelineSegment],
        transcriptLookup: TranscriptLookup
    ) -> [TimelineSegment]? {
        guard let normalizedRange = normalize(range: range, within: segments) else {
            return nil
        }

        var result: [TimelineSegment] = []
        var composedOffset = 0.0
        var changed = false

        for segment in segments {
            let segmentStart = composedOffset
            let segmentEnd = composedOffset + segment.durationSeconds
            defer { composedOffset = segmentEnd }

            let overlapStart = max(normalizedRange.startSeconds, segmentStart)
            let overlapEnd = min(normalizedRange.endSeconds, segmentEnd)
            guard overlapEnd > overlapStart + 0.001 else {
                result.append(segment)
                continue
            }

            changed = true

            if overlapStart > segmentStart + 0.001 {
                let leftEndSource = sourceTime(
                    for: segment,
                    segmentComposedStart: segmentStart,
                    composedTime: overlapStart
                )
                if let left = makeDerivedSegment(
                    from: segment,
                    range: TimeRange(startSeconds: segment.range.startSeconds, endSeconds: leftEndSource),
                    transcriptLookup: transcriptLookup
                ) {
                    result.append(left)
                }
            }

            if overlapEnd < segmentEnd - 0.001 {
                let rightStartSource = sourceTime(
                    for: segment,
                    segmentComposedStart: segmentStart,
                    composedTime: overlapEnd
                )
                if let right = makeDerivedSegment(
                    from: segment,
                    range: TimeRange(startSeconds: rightStartSource, endSeconds: segment.range.endSeconds),
                    transcriptLookup: transcriptLookup
                ) {
                    result.append(right)
                }
            }
        }

        return changed ? result : nil
    }

    /// Splice a slice of an arbitrary source recording into the
    /// composed timeline. See `AIAction.insertSourceClip` for the
    /// behaviour contract. Returns the mutated segment array, or `nil`
    /// when the source range is degenerate (the executor records this
    /// as `skipped`).
    private static func insertSourceClip(
        sourceVideoID: UUID,
        sourceStart: Double,
        sourceEnd: Double,
        composedInsertAt: Double,
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        in segments: [TimelineSegment],
        transcriptLookup: TranscriptLookup
    ) -> [TimelineSegment]? {
        let clipDuration = sourceEnd - sourceStart
        guard clipDuration > 0.01 else { return nil }
        guard sourceEnd > sourceStart else { return nil }

        let clipRange = TimeRange(startSeconds: sourceStart, endSeconds: sourceEnd)
        let subtitles = transcriptLookup([clipRange], sourceVideoID)
        let text = buildText(from: subtitles, fallback: "")

        // Fades are clamped to non-negative AND to half the clip
        // duration so a misconfigured tool call can't produce
        // overlapping fade-in/out curves that swallow the segment.
        let halfDuration = clipDuration / 2.0
        let safeFadeIn = max(0, min(fadeInSeconds, halfDuration))
        let safeFadeOut = max(0, min(fadeOutSeconds, halfDuration))

        var newSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: sourceVideoID,
            range: clipRange,
            text: text,
            subtitles: subtitles
        )
        var effects = SegmentEffects.default
        effects.audioFadeInDuration = safeFadeIn
        effects.audioFadeOutDuration = safeFadeOut
        newSegment.effects = effects

        let totalDuration = segments.reduce(0.0) { $0 + $1.durationSeconds }
        let clamped = max(0.0, min(composedInsertAt, totalDuration))

        // Walk segments accumulating composed offsets to find the
        // insert point.
        var composedOffset = 0.0
        var inserted = false
        var result: [TimelineSegment] = []
        result.reserveCapacity(segments.count + 2)

        for segment in segments {
            let segmentStart = composedOffset
            let segmentEnd = composedOffset + segment.durationSeconds
            defer { composedOffset = segmentEnd }

            // Land before this segment? Insert the new clip first.
            if !inserted && clamped <= segmentStart + 0.001 {
                result.append(newSegment)
                inserted = true
            }

            // Land strictly inside this segment? Split host, insert
            // new clip in the middle, then append the right half.
            if !inserted && clamped > segmentStart + 0.001
                && clamped < segmentEnd - 0.001 {
                let cutSourceTime = sourceTime(
                    for: segment,
                    segmentComposedStart: segmentStart,
                    composedTime: clamped
                )
                let leftRange = TimeRange(
                    startSeconds: segment.range.startSeconds,
                    endSeconds: cutSourceTime
                )
                let rightRange = TimeRange(
                    startSeconds: cutSourceTime,
                    endSeconds: segment.range.endSeconds
                )
                if var left = makeDerivedSegment(
                    from: segment,
                    range: leftRange,
                    transcriptLookup: transcriptLookup
                ), var right = makeDerivedSegment(
                    from: segment,
                    range: rightRange,
                    transcriptLookup: transcriptLookup
                ) {
                    // Clear interior-edge fades so a host segment with
                    // start/end fades doesn't bleed an unwanted dip
                    // into the new internal boundary on either side.
                    left.effects.audioFadeOutDuration = 0
                    right.effects.audioFadeInDuration = 0
                    result.append(left)
                    result.append(newSegment)
                    result.append(right)
                    inserted = true
                    continue
                }
                // Split failed (degenerate fragment) — fall through
                // and append the original segment, retry on next
                // boundary.
            }

            result.append(segment)
        }

        if !inserted {
            // Append-at-end (or empty timeline).
            result.append(newSegment)
        }

        return result
    }

    private static func setSpeedForComposedRange(
        range: TimeRange,
        rate: Double,
        in segments: [TimelineSegment],
        transcriptLookup: TranscriptLookup
    ) -> [TimelineSegment]? {
        guard let normalizedRange = normalize(range: range, within: segments) else {
            return nil
        }

        let clampedRate = clampRate(rate)
        var result: [TimelineSegment] = []
        var composedOffset = 0.0
        var changed = false

        for segment in segments {
            let segmentStart = composedOffset
            let segmentEnd = composedOffset + segment.durationSeconds
            defer { composedOffset = segmentEnd }

            let overlapStart = max(normalizedRange.startSeconds, segmentStart)
            let overlapEnd = min(normalizedRange.endSeconds, segmentEnd)
            guard overlapEnd > overlapStart + 0.001 else {
                result.append(segment)
                continue
            }

            guard abs(segment.normalizedSpeedRate - clampedRate) > 0.001 else {
                result.append(segment)
                continue
            }

            changed = true

            let fullyCovered = overlapStart <= segmentStart + 0.001 && overlapEnd >= segmentEnd - 0.001
            if fullyCovered {
                var updated = segment
                updated.speedRate = clampedRate
                result.append(updated)
                continue
            }

            if overlapStart > segmentStart + 0.001 {
                let leftEndSource = sourceTime(
                    for: segment,
                    segmentComposedStart: segmentStart,
                    composedTime: overlapStart
                )
                if let left = makeDerivedSegment(
                    from: segment,
                    range: TimeRange(startSeconds: segment.range.startSeconds, endSeconds: leftEndSource),
                    transcriptLookup: transcriptLookup
                ) {
                    result.append(left)
                }
            }

            let middleStartSource = sourceTime(
                for: segment,
                segmentComposedStart: segmentStart,
                composedTime: overlapStart
            )
            let middleEndSource = sourceTime(
                for: segment,
                segmentComposedStart: segmentStart,
                composedTime: overlapEnd
            )
            if let middle = makeDerivedSegment(
                from: segment,
                range: TimeRange(startSeconds: middleStartSource, endSeconds: middleEndSource),
                speedRate: clampedRate,
                transcriptLookup: transcriptLookup
            ) {
                result.append(middle)
            }

            if overlapEnd < segmentEnd - 0.001 {
                let rightStartSource = sourceTime(
                    for: segment,
                    segmentComposedStart: segmentStart,
                    composedTime: overlapEnd
                )
                if let right = makeDerivedSegment(
                    from: segment,
                    range: TimeRange(startSeconds: rightStartSource, endSeconds: segment.range.endSeconds),
                    transcriptLookup: transcriptLookup
                ) {
                    result.append(right)
                }
            }
        }

        return changed ? result : nil
    }

    private static func normalize(
        range: TimeRange,
        within segments: [TimelineSegment]
    ) -> TimeRange? {
        let totalDuration = segments.reduce(0.0) { $0 + $1.durationSeconds }
        guard totalDuration > 0 else { return nil }

        let lower = max(0, min(range.startSeconds, range.endSeconds))
        let upper = min(totalDuration, max(range.startSeconds, range.endSeconds))
        guard upper > lower + 0.05 else { return nil }

        return TimeRange(startSeconds: lower, endSeconds: upper)
    }

    private static func sourceTime(
        for segment: TimelineSegment,
        segmentComposedStart: Double,
        composedTime: Double
    ) -> Double {
        let clamped = max(segmentComposedStart, min(composedTime, segmentComposedStart + segment.durationSeconds))
        let relativeComposedTime = clamped - segmentComposedStart
        let sourceTime = segment.range.startSeconds + (relativeComposedTime * segment.normalizedSpeedRate)
        return max(segment.range.startSeconds, min(sourceTime, segment.range.endSeconds))
    }

    private static func makeDerivedSegment(
        from original: TimelineSegment,
        id: UUID? = nil,
        range: TimeRange,
        speedRate: Double? = nil,
        transcriptLookup: TranscriptLookup
    ) -> TimelineSegment? {
        guard range.endSeconds > range.startSeconds + 0.01 else {
            return nil
        }

        let subtitles = transcriptLookup([range], original.sourceVideoID)
        let text = buildText(from: subtitles, fallback: original.text)
        var segment = TimelineSegment(
            id: id ?? UUID(),
            sourceVideoID: original.sourceVideoID,
            range: range,
            text: text,
            subtitles: subtitles
        )
        segment.volumeLevel = original.volumeLevel
        segment.speedRate = speedRate ?? original.speedRate
        segment.effects = original.effects
        segment.alternatives = original.alternatives
        return segment
    }

    private static func buildText(from subtitles: [SubtitleEntry], fallback: String) -> String {
        let joined = subtitles
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? fallback : joined
    }

    private static func clampRate(_ rate: Double) -> Double {
        max(TimelineSegment.minimumSpeedRate, min(rate, TimelineSegment.maximumSpeedRate))
    }

    // MARK: - Subtitle helpers

    /// Finds the subtitle entry whose composed time-range contains
    /// `composedSeconds`. Iterates segments in order, accumulating composed
    /// start times (speed-adjusted via `durationSeconds`) and projecting each
    /// subtitle's relative range into composed space.
    public static func locateSubtitle(
        atComposedSeconds composedSeconds: Double,
        in segments: [TimelineSegment]
    ) -> UUID? {
        var composedOffset = 0.0
        for segment in segments {
            let segmentStart = composedOffset
            let segmentEnd = composedOffset + segment.durationSeconds
            defer { composedOffset = segmentEnd }
            guard composedSeconds >= segmentStart && composedSeconds < segmentEnd else {
                continue
            }
            // Subtitle relativeStart/relativeDuration are in composed time
            // (post-speed) within the segment, matching how the overlay
            // builds ComposedSubtitle cues.
            let within = composedSeconds - segmentStart
            // SubtitleEntry.relativeStart/Duration are in source-time
            // (pre-speed). Composed-time within the segment is source-time
            // divided by the segment's speed rate.
            let speed = segment.normalizedSpeedRate
            for entry in segment.subtitles {
                let s = entry.relativeStart / speed
                let e = (entry.relativeStart + entry.relativeDuration) / speed
                if within >= s && within < e { return entry.id }
            }
        }
        return nil
    }

    public static func findSubtitle(
        id: UUID,
        in segments: [TimelineSegment]
    ) -> (segment: Int, entry: Int)? {
        for (segIdx, seg) in segments.enumerated() {
            if let entryIdx = seg.subtitles.firstIndex(where: { $0.id == id }) {
                return (segIdx, entryIdx)
            }
        }
        return nil
    }

    /// Returns a closure that applies the configured find/replace rule to a
    /// single string. For regex patterns, returns nil when the pattern fails
    /// to compile — caller should skip the action in that case.
    public static func makeReplacer(
        find: String,
        replaceWith: String,
        isRegex: Bool
    ) -> ((String) -> String)? {
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: find) else {
                return nil
            }
            return { text in
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: replaceWith
                )
            }
        } else {
            return { $0.replacingOccurrences(of: find, with: replaceWith) }
        }
    }
}

import XCTest
import CuttiKit
@testable import CuttiMac

final class AIActionSystemTests: XCTestCase {
    private func makeRevision(
        id: UUID = UUID(),
        label: String,
        trigger: RevisionTrigger = .userEdit(description: "test")
    ) -> EditorRevision {
        EditorRevision(
            id: id,
            timestamp: Date(),
            label: label,
            segments: [],
            selectedSegmentID: nil,
            playheadSeconds: 0,
            trigger: trigger
        )
    }

    private func makeSegment(
        id: UUID = UUID(),
        sourceVideoID: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        start: Double,
        end: Double,
        speedRate: Double = 1.0,
        text: String = ""
    ) -> TimelineSegment {
        var segment = TimelineSegment(
            id: id,
            sourceVideoID: sourceVideoID,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: text,
            subtitles: []
        )
        segment.speedRate = speedRate
        return segment
    }

    func test_parseBatch_supportsReorderSegments() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString
        let args: [String: Any] = [
            "explanation": "Pull the pricing segment to the front as intro",
            "actions": [[
                "type": "reorder_segments",
                "segment_ids": [c, a, b]
            ]]
        ]

        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 1)

        if case let .reorderSegments(ids)? = batch?.actions.first {
            XCTAssertEqual(ids.map(\.uuidString), [c, a, b])
        } else {
            XCTFail("Expected reorderSegments action")
        }
    }

    func test_parseBatch_supportsRangeActions() {
        let args: [String: Any] = [
            "explanation": "Tighten the intro",
            "actions": [
                [
                    "type": "delete_range",
                    "start_time": 12,
                    "end_time": 24
                ],
                [
                    "type": "set_speed_range",
                    "start_time": 30,
                    "end_time": 42,
                    "rate": 1.5
                ]
            ]
        ]

        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 2)

        if case let .deleteRange(start, end)? = batch?.actions.first {
            XCTAssertEqual(start, 12, accuracy: 0.001)
            XCTAssertEqual(end, 24, accuracy: 0.001)
        } else {
            XCTFail("Expected deleteRange action")
        }

        if case let .setSpeedRange(start, end, rate)? = batch?.actions.last {
            XCTAssertEqual(start, 30, accuracy: 0.001)
            XCTAssertEqual(end, 42, accuracy: 0.001)
            XCTAssertEqual(rate, 1.5, accuracy: 0.001)
        } else {
            XCTFail("Expected setSpeedRange action")
        }
    }

    func test_parseBatch_supportsInsertSourceClip() {
        let sourceID = UUID()
        let args: [String: Any] = [
            "explanation": "Cold-open hook teaser",
            "actions": [[
                "type": "insert_source_clip",
                "source_video_id": sourceID.uuidString,
                "source_start": 132.4,
                "source_end": 137.9,
                "composed_insert_at": 0,
                "fade_in_seconds": 0.15,
                "fade_out_seconds": 0.30
            ]]
        ]
        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 1)
        guard case let .insertSourceClip(sid, ss, se, ci, fi, fo)? = batch?.actions.first else {
            return XCTFail("Expected insertSourceClip action")
        }
        XCTAssertEqual(sid, sourceID)
        XCTAssertEqual(ss, 132.4, accuracy: 0.001)
        XCTAssertEqual(se, 137.9, accuracy: 0.001)
        XCTAssertEqual(ci, 0, accuracy: 0.001)
        XCTAssertEqual(fi, 0.15, accuracy: 0.001)
        XCTAssertEqual(fo, 0.30, accuracy: 0.001)
    }

    func test_parseBatch_insertSourceClip_omittedComposedInsertAt_isRejected() {
        // Parser-side rejection: composed_insert_at is required so a
        // dropped argument doesn't silently become a destructive
        // prepend at 0. The validator never even sees this batch.
        let args: [String: Any] = [
            "explanation": "missing composed_insert_at",
            "actions": [[
                "type": "insert_source_clip",
                "source_video_id": UUID().uuidString,
                "source_start": 1.0,
                "source_end": 4.0
            ]]
        ]
        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 0)
    }

    func test_parseBatch_insertSourceClip_omittedFades_useDefaults() {
        let sid = UUID()
        let args: [String: Any] = [
            "explanation": "default fades",
            "actions": [[
                "type": "insert_source_clip",
                "source_video_id": sid.uuidString,
                "source_start": 0.0,
                "source_end": 5.0,
                "composed_insert_at": 0
            ]]
        ]
        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 1)
        guard case let .insertSourceClip(_, _, _, _, fi, fo)? = batch?.actions.first else {
            return XCTFail("Expected insertSourceClip action")
        }
        XCTAssertEqual(fi, 0.15, accuracy: 0.001)
        XCTAssertEqual(fo, 0.30, accuracy: 0.001)
    }

    func test_deleteRange_trimsAcrossSegments() {
        let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let segments = [
            makeSegment(sourceVideoID: sourceID, start: 0, end: 4, text: "A"),
            makeSegment(sourceVideoID: sourceID, start: 10, end: 14, text: "B"),
            makeSegment(sourceVideoID: sourceID, start: 20, end: 24, text: "C")
        ]

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.deleteRange(start: 2, end: 7)],
                explanation: "Delete the middle chunk"
            ),
            to: segments,
            transcriptLookup: { _, _ in [] }
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].range.endSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.startSeconds, 13, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.endSeconds, 14, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].range.startSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].range.endSeconds, 24, accuracy: 0.001)
    }

    func test_setSpeedRange_splitsSegmentAndShortensDuration() {
        let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let segments = [
            makeSegment(sourceVideoID: sourceID, start: 0, end: 10, text: "Long segment")
        ]

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.setSpeedRange(start: 2, end: 8, rate: 2.0)],
                explanation: "Speed up the middle"
            ),
            to: segments,
            transcriptLookup: { _, _ in [] }
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].range.endSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(result.segments[0].normalizedSpeedRate, 1.0, accuracy: 0.001)

        XCTAssertEqual(result.segments[1].range.startSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].range.endSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].normalizedSpeedRate, 2.0, accuracy: 0.001)
        XCTAssertEqual(result.segments[1].durationSeconds, 3.0, accuracy: 0.001)

        XCTAssertEqual(result.segments[2].range.startSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].range.endSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(result.segments[2].normalizedSpeedRate, 1.0, accuracy: 0.001)
    }

    func test_composedTimelineIndex_accountsForSpeedRate() {
        let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let segments = [
            makeSegment(sourceVideoID: sourceID, start: 10, end: 14, speedRate: 2.0, text: "Fast")
        ]

        let index = ComposedTimelineIndex.build(from: segments)

        XCTAssertEqual(index.totalDuration, 2.0, accuracy: 0.001)

        let sourceMapping = index.toSourceTime(1.5)
        XCTAssertEqual(sourceMapping?.sourceVideoID, sourceID)
        XCTAssertNotNil(sourceMapping)
        XCTAssertEqual(sourceMapping?.sourceTime ?? 0, 13.0, accuracy: 0.001)

        let composedTime = index.toComposedTime(sourceVideoID: sourceID, sourceTime: 13.0)
        XCTAssertNotNil(composedTime)
        XCTAssertEqual(composedTime ?? 0, 1.5, accuracy: 0.001)
    }

    func test_restoreCheckpointRequest_parseSupportsHistoryIndex() {
        let args: [String: Any] = [
            "checkpoint_index": 0,
            "reason": "Undo the last change"
        ]

        let request = RestoreCheckpointRequest.parse(from: args)

        XCTAssertEqual(request?.checkpointIndex, 0)
        XCTAssertNil(request?.checkpointID)
        XCTAssertEqual(request?.reason, "Undo the last change")
    }

    func test_restoreCheckpointRequest_resolvesHistoryByIndex() {
        let older = makeRevision(label: "Split segment")
        let newer = makeRevision(label: "Change speed")
        let history = [newer, older]

        let request = RestoreCheckpointRequest(
            checkpointID: nil,
            checkpointIndex: 1,
            reason: nil
        )

        let resolved = request.resolveCheckpoint(from: history, allRevisions: [older, newer])
        XCTAssertEqual(resolved?.id, older.id)
        XCTAssertEqual(resolved?.label, "Split segment")
    }

    // MARK: - Subtitle actions

    private func makeSubtitleSegment(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        subtitles: [SubtitleEntry]
    ) -> TimelineSegment {
        TimelineSegment(
            id: id,
            sourceVideoID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: subtitles.map(\.text).joined(separator: " "),
            subtitles: subtitles
        )
    }

    func test_editSubtitle_byID_replacesText() {
        let subID = UUID()
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 5,
                subtitles: [
                    SubtitleEntry(id: subID, relativeStart: 0, relativeDuration: 5, text: "Hello world")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.editSubtitle(id: subID, atSeconds: nil, newText: "Hi there")],
                explanation: "rewrite"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles.first?.text, "Hi there")
    }

    func test_editSubtitle_byTime_locatesCorrectCue() {
        let a = UUID(), b = UUID()
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 10,
                subtitles: [
                    SubtitleEntry(id: a, relativeStart: 0, relativeDuration: 4, text: "first"),
                    SubtitleEntry(id: b, relativeStart: 4, relativeDuration: 6, text: "second")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.editSubtitle(id: nil, atSeconds: 6, newText: "SECOND")],
                explanation: "retarget"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles[0].text, "first")
        XCTAssertEqual(result.segments.first?.subtitles[1].text, "SECOND")
    }

    func test_editSubtitle_skipsEmptyText() {
        let subID = UUID()
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 2,
                subtitles: [
                    SubtitleEntry(id: subID, relativeStart: 0, relativeDuration: 2, text: "keep")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.editSubtitle(id: subID, atSeconds: nil, newText: "   ")],
                explanation: "noop"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles.first?.text, "keep")
    }

    func test_replaceSubtitleText_plainString() {
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 6,
                subtitles: [
                    SubtitleEntry(id: UUID(), relativeStart: 0, relativeDuration: 3, text: "uh hello uh world"),
                    SubtitleEntry(id: UUID(), relativeStart: 3, relativeDuration: 3, text: "no fillers")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.replaceSubtitleText(find: "uh ", replaceWith: "", isRegex: false)],
                explanation: "strip"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles[0].text, "hello world")
        XCTAssertEqual(result.segments.first?.subtitles[1].text, "no fillers")
    }

    func test_replaceSubtitleText_regexWithCaptureGroup() {
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 3,
                subtitles: [
                    SubtitleEntry(id: UUID(), relativeStart: 0, relativeDuration: 3, text: "Hello Alice and Bob")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.replaceSubtitleText(find: "(Alice|Bob)", replaceWith: "[$1]", isRegex: true)],
                explanation: "bracket names"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles.first?.text, "Hello [Alice] and [Bob]")
    }

    func test_replaceSubtitleText_invalidRegexSkipped() {
        let segs = [
            makeSubtitleSegment(
                start: 0, end: 2,
                subtitles: [
                    SubtitleEntry(id: UUID(), relativeStart: 0, relativeDuration: 2, text: "keep me")
                ]
            )
        ]
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.replaceSubtitleText(find: "[unclosed", replaceWith: "x", isRegex: true)],
                explanation: "bad"
            ),
            to: segs,
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.segments.first?.subtitles.first?.text, "keep me")
    }

    func test_setSubtitleStyle_patchesSelectedFieldsOnly() {
        var base = SubtitleStyle.default
        base.fontSizePoints = 48
        base.textColor = .white
        base.backgroundColor = SubtitleStyle.RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)

        var patch = SubtitleStylePatch()
        patch.fontSizePoints = 72
        patch.backgroundOpacity = 0.9

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.setSubtitleStyle(patch: patch)],
                explanation: "bigger and more solid"
            ),
            to: [],
            baseSubtitleStyle: base,
            transcriptLookup: { _, _ in [] }
        )

        XCTAssertEqual(result.appliedCount, 1)
        let style = result.subtitleStyle
        XCTAssertNotNil(style)
        XCTAssertEqual(style?.fontSizePoints ?? 0, 72, accuracy: 0.001)
        // textColor unchanged
        XCTAssertEqual(style?.textColor, .white)
        // only alpha of backgroundColor changed
        XCTAssertEqual(style?.backgroundColor.red ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(style?.backgroundColor.alpha ?? -1, 0.9, accuracy: 0.001)
    }

    func test_setSubtitleStyle_clampsOutOfRangeValues() {
        var patch = SubtitleStylePatch()
        patch.fontSizePoints = 9999
        patch.maxWidthFraction = 5
        patch.verticalPositionFraction = -1

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.setSubtitleStyle(patch: patch)],
                explanation: "bogus"
            ),
            to: [],
            baseSubtitleStyle: .default,
            transcriptLookup: { _, _ in [] }
        )

        let style = result.subtitleStyle
        XCTAssertEqual(style?.fontSizePoints ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(style?.maxWidthFraction ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(style?.verticalPositionFraction ?? -99, 0, accuracy: 0.001)
    }

    func test_setSubtitlesVisible_reportsFlag() {
        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.setSubtitlesVisible(visible: false)],
                explanation: "hide"
            ),
            to: [],
            transcriptLookup: { _, _ in [] }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.showSubtitles, false)
    }

    func test_parseBatch_supportsSubtitleActions() {
        let args: [String: Any] = [
            "explanation": "tune subs",
            "actions": [
                [
                    "type": "edit_subtitle",
                    "at_time": 5.5,
                    "new_text": "Hello there"
                ],
                [
                    "type": "replace_subtitle_text",
                    "find": "uh ",
                    "replace_with": "",
                    "is_regex": false
                ],
                [
                    "type": "set_subtitle_style",
                    "font_size_points": 60,
                    "text_color": "#FFCC00",
                    "background_opacity": 0.7
                ],
                [
                    "type": "set_subtitles_visible",
                    "visible": true
                ]
            ]
        ]
        let batch = AIAction.parseBatch(from: args)
        XCTAssertEqual(batch?.actions.count, 4)

        guard let actions = batch?.actions else { return XCTFail("no batch") }

        if case let .editSubtitle(id, atSeconds, newText) = actions[0] {
            XCTAssertNil(id)
            XCTAssertEqual(atSeconds ?? 0, 5.5, accuracy: 0.001)
            XCTAssertEqual(newText, "Hello there")
        } else { XCTFail("expected editSubtitle") }

        if case let .replaceSubtitleText(find, replaceWith, isRegex) = actions[1] {
            XCTAssertEqual(find, "uh ")
            XCTAssertEqual(replaceWith, "")
            XCTAssertFalse(isRegex)
        } else { XCTFail("expected replace") }

        if case let .setSubtitleStyle(patch) = actions[2] {
            XCTAssertEqual(patch.fontSizePoints ?? 0, 60, accuracy: 0.001)
            XCTAssertEqual(patch.textColor?.red ?? 0, 1.0, accuracy: 0.001)
            XCTAssertEqual(patch.textColor?.green ?? 0, 0.8, accuracy: 0.01)
            XCTAssertEqual(patch.backgroundOpacity ?? 0, 0.7, accuracy: 0.001)
        } else { XCTFail("expected setSubtitleStyle") }

        if case let .setSubtitlesVisible(visible) = actions[3] {
            XCTAssertTrue(visible)
        } else { XCTFail("expected setSubtitlesVisible") }
    }

    func test_parseHexColor_handlesWithAndWithoutAlpha() {
        let rgb = SubtitleStylePatch.parseHexColor("#FF8040")
        XCTAssertEqual(rgb?.red ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.green ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(rgb?.blue ?? 0, 0.25, accuracy: 0.01)
        XCTAssertEqual(rgb?.alpha ?? 0, 1.0, accuracy: 0.001)

        let rgba = SubtitleStylePatch.parseHexColor("#00000080")
        XCTAssertEqual(rgba?.alpha ?? 0, 0.502, accuracy: 0.01)

        XCTAssertNil(SubtitleStylePatch.parseHexColor("not a color"))
    }
}

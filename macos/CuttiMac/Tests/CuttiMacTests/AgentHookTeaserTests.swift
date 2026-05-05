import XCTest
import CuttiKit
@testable import CuttiMac

final class AgentHookTeaserTests: XCTestCase {

    // MARK: - Fixtures

    private let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let imageID  = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeRecord(
        id: UUID,
        kind: MediaKind = .video,
        durationSeconds: Double? = 60.0,
        sourcePath: String = "/tmp/source.mov"
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: sourcePath,
            fingerprint: SourceFingerprint(fileSize: 100, modifiedAt: .distantPast, sha256Prefix: "ab"),
            status: .ready,
            analysis: durationSeconds.map {
                AnalysisSummary(durationSeconds: $0, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true)
            },
            derived: DerivedAssetState(thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: nil,
            kind: kind
        )
    }

    private func validArgs(
        start: Double = 10.0,
        end: Double = 14.5,
        audioTail: Double? = nil,
        fadeIn: Double? = nil,
        explanation: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "source_video_id": sourceID.uuidString,
            "source_start": start,
            "source_end": end
        ]
        if let v = audioTail { dict["audio_tail_seconds"] = v }
        if let v = fadeIn { dict["fade_in_seconds"] = v }
        if let v = explanation { dict["explanation"] = v }
        return dict
    }

    // MARK: - Happy path

    func test_parse_happyPath() throws {
        let records = [makeRecord(id: sourceID, sourcePath: "/tmp/podcast.mov")]
        let result = AgentHook.parseHookTeaserArgs(args: validArgs(), records: records)
        guard case .success(let inputs) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertEqual(inputs.sourceVideoID, sourceID)
        XCTAssertEqual(inputs.sourceStart, 10.0)
        XCTAssertEqual(inputs.sourceEnd, 14.5)
        XCTAssertEqual(inputs.audioTailSeconds, 0.4) // default
        XCTAssertEqual(inputs.fadeInSeconds, 0.15)   // default
        XCTAssertEqual(inputs.sourceName, "podcast.mov")
        XCTAssertTrue(inputs.explanation.contains("podcast.mov"))
        XCTAssertTrue(inputs.explanation.contains("4.5s"))
    }

    func test_buildBatch_singleInsertSourceClipAtZero() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(), records: records) else {
            XCTFail("parse failed")
            return
        }
        let batch = AgentHook.buildHookBatch(inputs)
        XCTAssertEqual(batch.actions.count, 1)
        guard case .insertSourceClip(let sid, let start, let end, let composedAt, let fadeIn, let fadeOut) = batch.actions[0] else {
            XCTFail("expected insertSourceClip action")
            return
        }
        XCTAssertEqual(sid, sourceID)
        XCTAssertEqual(start, 10.0)
        XCTAssertEqual(end, 14.5)
        XCTAssertEqual(composedAt, 0.0, "hook must always insert at composed time 0")
        XCTAssertEqual(fadeIn, 0.15)
        XCTAssertEqual(fadeOut, 0.4)
    }

    // MARK: - Defaults & clamping

    func test_parse_audioTailDefault() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(), records: records) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(inputs.audioTailSeconds, 0.4)
    }

    func test_parse_audioTailCustomValuePreserved() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(audioTail: 0.75), records: records) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(inputs.audioTailSeconds, 0.75)
    }

    func test_parse_audioTailClampedHigh() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(audioTail: 5.0), records: records) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(inputs.audioTailSeconds, 2.0, "audio tail clamped to max 2.0")
    }

    func test_parse_audioTailClampedLow() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(audioTail: -1.0), records: records) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(inputs.audioTailSeconds, 0.0, "audio tail clamped to min 0")
    }

    func test_parse_fadeInClamped() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: validArgs(fadeIn: 5.0), records: records) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(inputs.fadeInSeconds, 1.0)
    }

    func test_parse_intArgsAccepted() {
        // LLMs sometimes return integers for whole-second values.
        let records = [makeRecord(id: sourceID)]
        let args: [String: Any] = [
            "source_video_id": sourceID.uuidString,
            "source_start": 3,
            "source_end": 8
        ]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(args: args, records: records) else {
            XCTFail("parse failed for int args"); return
        }
        XCTAssertEqual(inputs.sourceStart, 3.0)
        XCTAssertEqual(inputs.sourceEnd, 8.0)
    }

    func test_parse_explanationOverridePreserved() {
        let records = [makeRecord(id: sourceID)]
        guard case .success(let inputs) = AgentHook.parseHookTeaserArgs(
            args: validArgs(explanation: "Custom hook title"),
            records: records
        ) else { XCTFail("parse failed"); return }
        XCTAssertEqual(inputs.explanation, "Custom hook title")
    }

    // MARK: - Error paths

    func test_parse_missingSourceVideoID() {
        let records = [makeRecord(id: sourceID)]
        var args = validArgs()
        args.removeValue(forKey: "source_video_id")
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: args, records: records) else {
            XCTFail("expected failure"); return
        }
        XCTAssertEqual(err, .missingArg("source_video_id"))
    }

    func test_parse_invalidUUID() {
        let records = [makeRecord(id: sourceID)]
        var args = validArgs()
        args["source_video_id"] = "not-a-uuid"
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: args, records: records) else {
            XCTFail("expected failure"); return
        }
        if case .invalidUUID = err {} else { XCTFail("expected invalidUUID, got \(err)") }
    }

    func test_parse_missingStart() {
        let records = [makeRecord(id: sourceID)]
        var args = validArgs()
        args.removeValue(forKey: "source_start")
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: args, records: records) else {
            XCTFail("expected failure"); return
        }
        XCTAssertEqual(err, .missingArg("source_start"))
    }

    func test_parse_missingEnd() {
        let records = [makeRecord(id: sourceID)]
        var args = validArgs()
        args.removeValue(forKey: "source_end")
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: args, records: records) else {
            XCTFail("expected failure"); return
        }
        XCTAssertEqual(err, .missingArg("source_end"))
    }

    func test_parse_invertedRange() {
        let records = [makeRecord(id: sourceID)]
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: 8, end: 3),
            records: records
        ) else { XCTFail("expected failure"); return }
        if case .invalidRange = err {} else { XCTFail("expected invalidRange, got \(err)") }
    }

    func test_parse_zeroLengthRange() {
        let records = [makeRecord(id: sourceID)]
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: 5, end: 5),
            records: records
        ) else { XCTFail("expected failure"); return }
        if case .invalidRange = err {} else { XCTFail("expected invalidRange, got \(err)") }
    }

    func test_parse_negativeStart() {
        let records = [makeRecord(id: sourceID)]
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: -1, end: 5),
            records: records
        ) else { XCTFail("expected failure"); return }
        if case .invalidRange = err {} else { XCTFail("expected invalidRange, got \(err)") }
    }

    func test_parse_sourceNotInRecords() {
        let records: [MediaAssetRecord] = []
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: validArgs(), records: records) else {
            XCTFail("expected failure"); return
        }
        if case .sourceNotFound = err {} else { XCTFail("expected sourceNotFound, got \(err)") }
    }

    func test_parse_sourceIsImageNotVideo() {
        let records = [makeRecord(id: sourceID, kind: .image, durationSeconds: nil)]
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(args: validArgs(), records: records) else {
            XCTFail("expected failure"); return
        }
        if case .sourceNotVideo = err {} else { XCTFail("expected sourceNotVideo, got \(err)") }
    }

    func test_parse_rangePastSourceDuration() {
        let records = [makeRecord(id: sourceID, durationSeconds: 10.0)]
        guard case .failure(let err) = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: 8, end: 15),
            records: records
        ) else { XCTFail("expected failure"); return }
        if case .sourceRangeOutOfBounds = err {} else { XCTFail("expected out-of-bounds, got \(err)") }
    }

    func test_parse_rangeAtSourceDurationBoundary() {
        // Exactly at duration is allowed (with 0.05s epsilon for FP rounding).
        let records = [makeRecord(id: sourceID, durationSeconds: 10.0)]
        let result = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: 5, end: 10.0),
            records: records
        )
        if case .failure(let err) = result {
            XCTFail("boundary should pass, got \(err)")
        }
    }

    func test_parse_unknownDurationDoesNotErrorOnBounds() {
        // Records without analysis (still being analyzed) should not
        // fail bounds check — the executor will clamp at apply time.
        let records = [makeRecord(id: sourceID, durationSeconds: nil)]
        let result = AgentHook.parseHookTeaserArgs(
            args: validArgs(start: 5, end: 100),
            records: records
        )
        if case .failure(let err) = result {
            XCTFail("missing analysis should not block parsing, got \(err)")
        }
    }
}

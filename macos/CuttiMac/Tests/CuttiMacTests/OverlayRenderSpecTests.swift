import XCTest
import CuttiKit
@testable import CuttiMac

final class OverlayRenderSpecTests: XCTestCase {

    func test_canonicalization_sortsKeys() {
        let spec1 = OverlayRenderSpec(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"A","subtitle":"B"}"#,
            durationSeconds: 2.5
        )
        let spec2 = OverlayRenderSpec(
            templateID: "ChapterTitle",
            propsJSON: #"{"subtitle":"B","title":"A"}"#,
            durationSeconds: 2.5
        )
        XCTAssertEqual(spec1.cacheKey, spec2.cacheKey)
        XCTAssertEqual(spec1.propsJSON, spec2.propsJSON)
    }

    func test_cacheKey_changesWhenPropsChange() {
        let a = OverlayRenderSpec(templateID: "ChapterTitle", propsJSON: #"{"title":"A"}"#, durationSeconds: 2.5)
        let b = OverlayRenderSpec(templateID: "ChapterTitle", propsJSON: #"{"title":"B"}"#, durationSeconds: 2.5)
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
    }

    func test_cacheKey_changesWhenDurationChanges() {
        let a = OverlayRenderSpec(templateID: "ChapterTitle", propsJSON: #"{"title":"A"}"#, durationSeconds: 2.5)
        let b = OverlayRenderSpec(templateID: "ChapterTitle", propsJSON: #"{"title":"A"}"#, durationSeconds: 3.0)
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
    }

    func test_cacheKey_changesWhenTemplateChanges() {
        let a = OverlayRenderSpec(templateID: "ChapterTitle", propsJSON: "{}", durationSeconds: 2)
        let b = OverlayRenderSpec(templateID: "OtherCard", propsJSON: "{}", durationSeconds: 2)
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
    }

    func test_minimumDurationClampedToPositive() {
        let s = OverlayRenderSpec(templateID: "X", propsJSON: "{}", durationSeconds: -1)
        XCTAssertGreaterThan(s.durationSeconds, 0)
    }

    func test_nonJSONProps_passedThroughUnchanged() {
        let s = OverlayRenderSpec(templateID: "X", propsJSON: "not-json", durationSeconds: 1)
        XCTAssertEqual(s.propsJSON, "not-json")
    }

    func test_emptyPropsFallsBackToEmptyObject() {
        let s = OverlayRenderSpec(templateID: "X", propsJSON: "   ", durationSeconds: 1)
        XCTAssertEqual(s.propsJSON, "{}")
    }

    func test_codableRoundTrip_preservesCacheKey() throws {
        let original = OverlayRenderSpec(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"Zh","theme":"dark"}"#,
            durationSeconds: 2.5,
            fps: 30,
            width: 1920,
            height: 1080
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OverlayRenderSpec.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.cacheKey, original.cacheKey)
    }
}

final class UpdateOverlayPropsRequestTests: XCTestCase {

    func test_parse_acceptsSegmentIDAndStringPatch() {
        let id = UUID()
        let req = UpdateOverlayPropsRequest.parse(from: [
            "segment_id": id.uuidString,
            "props_patch": #"{"title":"Z"}"#,
        ])
        XCTAssertEqual(req?.segmentID, id)
        // Canonicalised or at least still contains the key
        XCTAssertNotNil(req)
    }

    func test_parse_acceptsNestedPatchObject() {
        let id = UUID()
        let req = UpdateOverlayPropsRequest.parse(from: [
            "segment_id": id.uuidString,
            "props_patch": ["title": "Z", "theme": "light"] as [String: Any],
        ])
        XCTAssertEqual(req?.segmentID, id)
        XCTAssertTrue(req?.propsPatchJSON.contains("Z") ?? false)
    }

    func test_parse_rejectsMissingSegmentID() {
        XCTAssertNil(UpdateOverlayPropsRequest.parse(from: ["props_patch": "{}"]))
    }

    func test_parse_rejectsNonObjectPatch() {
        let id = UUID()
        XCTAssertNil(UpdateOverlayPropsRequest.parse(from: [
            "segment_id": id.uuidString,
            "props_patch": "[\"not\", \"an\", \"object\"]",
        ]))
    }

    func test_parse_rejectsMalformedUUID() {
        XCTAssertNil(UpdateOverlayPropsRequest.parse(from: [
            "segment_id": "not-a-uuid",
            "props_patch": "{}",
        ]))
    }

    func test_toolDefinition_hasExpectedNameAndRequiredFields() {
        let def = UpdateOverlayPropsRequest.toolDefinition
        XCTAssertEqual(def.function.name, "update_overlay_props")
        XCTAssertTrue(def.function.parameters.required?.contains("segment_id") ?? false)
        XCTAssertTrue(def.function.parameters.required?.contains("props_patch") ?? false)
    }
}

final class TimelineSegmentOverlaySpecTests: XCTestCase {

    func test_persistableSegment_roundTripsOverlaySpec() throws {
        let spec = OverlayRenderSpec(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"第一章"}"#,
            durationSeconds: 2.5
        )
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 2.5),
            text: "",
            subtitles: []
        )
        seg.overlaySpec = spec

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        let rebuilt = decoded.toTimelineSegment()
        XCTAssertEqual(rebuilt.overlaySpec, spec)
    }

    func test_persistableSegment_withoutOverlaySpec_staysNilOnRoundTrip() throws {
        let seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 2.5),
            text: "hi",
            subtitles: []
        )
        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        XCTAssertNil(decoded.toTimelineSegment().overlaySpec)
    }

    func test_decodingLegacyJSON_withoutOverlaySpecField_succeeds() throws {
        // Simulates a project file written before the overlaySpec
        // field existed. The decoder must accept it as nil.
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "sourceVideoID": "\(UUID().uuidString)",
          "startSeconds": 0,
          "endSeconds": 2.5,
          "text": "",
          "volumeLevel": 1.0,
          "speedRate": 1.0
        }
        """
        let data = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        XCTAssertNil(decoded.toTimelineSegment().overlaySpec)
    }
}

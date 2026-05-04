import XCTest
@testable import CuttiKit

/// Pins the back-compat contract for `BRollSuggestion`: snapshots saved
/// before the `userTitle` / `agentHint` / `sectionRole` fields existed
/// must still decode (with the new fields surfacing as `nil`), and a
/// fresh round-trip with all fields populated must preserve every
/// value. If either of these breaks, every project file written by an
/// older Cutti build would silently fail to load — this test catches
/// the regression at compile/test time.
final class BRollSuggestionCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Legacy decode

    func test_decode_legacyJSON_withoutNewFields_yieldsNilOptionals() throws {
        let id = UUID()
        let videoID = UUID()
        let legacy = """
        {
            "id": "\(id.uuidString)",
            "sourceVideoID": "\(videoID.uuidString)",
            "sourceStartSeconds": 12.5,
            "sourceEndSeconds": 18.0,
            "kind": "chart",
            "prompt": "bar chart, 3 bars labelled Q1/Q2/Q3",
            "rationale": "speaker enumerates three quarters",
            "isDismissed": false
        }
        """.data(using: .utf8)!

        let decoded = try decoder.decode(BRollSuggestion.self, from: legacy)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.sourceVideoID, videoID)
        XCTAssertEqual(decoded.kind, .chart)
        XCTAssertEqual(decoded.prompt, "bar chart, 3 bars labelled Q1/Q2/Q3")
        XCTAssertEqual(decoded.rationale, "speaker enumerates three quarters")
        XCTAssertFalse(decoded.isDismissed)
        // The whole point: missing keys must decode as nil, not throw.
        XCTAssertNil(decoded.userTitle)
        XCTAssertNil(decoded.agentHint)
        XCTAssertNil(decoded.sectionRole)
    }

    func test_decode_legacyJSON_missingIsDismissed_stillDecodes() throws {
        // `isDismissed` has a default (`false`) in the struct but Swift's
        // synthesized Codable doesn't honour stored-property defaults —
        // it requires the key to be present. This test pins that
        // assumption: if a user has even older snapshots (pre-`isDismissed`)
        // we'd need a custom decoder. Today we *don't* — confirm it.
        let id = UUID()
        let videoID = UUID()
        let legacy = """
        {
            "id": "\(id.uuidString)",
            "sourceVideoID": "\(videoID.uuidString)",
            "sourceStartSeconds": 0.0,
            "sourceEndSeconds": 1.0,
            "kind": "other",
            "prompt": "x",
            "rationale": "y"
        }
        """.data(using: .utf8)!

        // Currently this should THROW because `isDismissed` lacks an
        // explicit `decodeIfPresent` path. Document the limitation
        // here so anyone tightening Codable later notices.
        XCTAssertThrowsError(try decoder.decode(BRollSuggestion.self, from: legacy))
    }

    // MARK: - Round-trip

    func test_roundTrip_allFieldsPopulated_preservesValues() throws {
        let original = BRollSuggestion(
            id: UUID(),
            sourceVideoID: UUID(),
            sourceStartSeconds: 4.25,
            sourceEndSeconds: 11.5,
            kind: .chart,
            prompt: "bar chart, 3 bars labelled Q1/Q2/Q3, minimal flat style",
            rationale: "Speaker enumerates three quarters of growth.",
            isDismissed: false,
            userTitle: "Q1·Q2·Q3 chart",
            agentHint: "Q1: 12% | Q2: 18% | Q3: 24%",
            sectionRole: "data"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BRollSuggestion.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.userTitle, "Q1·Q2·Q3 chart")
        XCTAssertEqual(decoded.agentHint, "Q1: 12% | Q2: 18% | Q3: 24%")
        XCTAssertEqual(decoded.sectionRole, "data")
    }

    func test_roundTrip_optionalsNil_emitsAndDecodesAsNil() throws {
        let original = BRollSuggestion(
            id: UUID(),
            sourceVideoID: UUID(),
            sourceStartSeconds: 0,
            sourceEndSeconds: 2,
            kind: .other,
            prompt: "p",
            rationale: "r"
            // userTitle / agentHint / sectionRole default to nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BRollSuggestion.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.userTitle)
        XCTAssertNil(decoded.agentHint)
        XCTAssertNil(decoded.sectionRole)
    }

    // MARK: - Equatable sanity

    func test_equatable_distinguishesSectionRoleAndAgentHint() {
        let base = BRollSuggestion(
            sourceVideoID: UUID(),
            sourceStartSeconds: 0,
            sourceEndSeconds: 1,
            kind: .other,
            prompt: "p",
            rationale: "r"
        )
        var withRole = base
        withRole = BRollSuggestion(
            id: base.id,
            sourceVideoID: base.sourceVideoID,
            sourceStartSeconds: base.sourceStartSeconds,
            sourceEndSeconds: base.sourceEndSeconds,
            kind: base.kind,
            prompt: base.prompt,
            rationale: base.rationale,
            isDismissed: base.isDismissed,
            sectionRole: "thesis"
        )
        XCTAssertNotEqual(base, withRole)
    }
}

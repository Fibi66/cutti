import XCTest
@testable import CuttiMac
@testable import CuttiKit

/// Pins the contract on the static helpers `BRollSuggestionService`
/// exposes for parsing LLM output into structured types.
///
/// The full two-phase suggestion pipeline calls the network so it
/// can't run from a unit test cheaply. But the failure modes that
/// actually break in production are at the parsing seam: the LLM
/// returns a slightly off-schema role, or omits an optional field,
/// or sticks with the legacy boolean `benefits_visual` shape after
/// we ship the new enum schema. These tests cover those.
@MainActor
final class BRollSuggestionServiceParsingTests: XCTestCase {

    // MARK: - canonicalRole

    func test_canonicalRole_acceptsAllAllowedValues() {
        let allowed = [
            "intro", "thesis", "setup", "enumeration", "process",
            "chronology", "example", "comparison", "quote", "data",
            "anecdote", "emotional", "transition", "conclusion", "other",
        ]
        for r in allowed {
            XCTAssertEqual(
                BRollSuggestionService.canonicalRole(r),
                r,
                "Allowed role '\(r)' was not preserved"
            )
        }
    }

    func test_canonicalRole_lowercasesAndTrims() {
        XCTAssertEqual(BRollSuggestionService.canonicalRole("  Quote  "), "quote")
        XCTAssertEqual(BRollSuggestionService.canonicalRole("ENUMERATION"), "enumeration")
        XCTAssertEqual(BRollSuggestionService.canonicalRole("\nProcess\n"), "process")
    }

    func test_canonicalRole_unknownCollapsesToOther() {
        XCTAssertEqual(BRollSuggestionService.canonicalRole("monologue"), "other")
        XCTAssertEqual(BRollSuggestionService.canonicalRole(""), "other")
        XCTAssertEqual(BRollSuggestionService.canonicalRole("   "), "other")
        XCTAssertEqual(BRollSuggestionService.canonicalRole("introduction"), "other")
    }

    func test_canonicalRole_nilCollapsesToOther() {
        XCTAssertEqual(BRollSuggestionService.canonicalRole(nil), "other")
    }

    // MARK: - VisualBenefit.parse

    func test_visualBenefit_parsesEachStringValue() {
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("none"), .none)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("low"), .low)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("medium"), .medium)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("high"), .high)
    }

    func test_visualBenefit_isCaseAndWhitespaceTolerant() {
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("  HIGH  "), .high)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("Medium"), .medium)
    }

    func test_visualBenefit_unknownStringBecomesNone() {
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse("maybe"), .none)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse(""), .none)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse(nil), .none)
    }

    func test_visualBenefit_legacyBoolStillWorks() {
        // Older model snapshots that haven't picked up the new schema
        // still emit `benefits_visual: true|false`. The parser must
        // tolerate that or every suggestion request to those models
        // collapses to "none".
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse(true), .high)
        XCTAssertEqual(BRollSuggestionService.VisualBenefit.parse(false), .none)
    }

    func test_visualBenefit_rankOrdering() {
        XCTAssertLessThan(
            BRollSuggestionService.VisualBenefit.none.rank,
            BRollSuggestionService.VisualBenefit.low.rank
        )
        XCTAssertLessThan(
            BRollSuggestionService.VisualBenefit.low.rank,
            BRollSuggestionService.VisualBenefit.medium.rank
        )
        XCTAssertLessThan(
            BRollSuggestionService.VisualBenefit.medium.rank,
            BRollSuggestionService.VisualBenefit.high.rank
        )
    }

    // MARK: - roleRoutingHint

    func test_roleRoutingHint_enumerationRoutesToList() {
        let en = MediaCoreViewModel.roleRoutingHint("enumeration", isEnglish: true)
        XCTAssertTrue(en.contains("SequenceSteps"), "Got: \(en)")
        XCTAssertTrue(en.contains("list"), "Got: \(en)")

        let zh = MediaCoreViewModel.roleRoutingHint("enumeration", isEnglish: false)
        XCTAssertTrue(zh.contains("SequenceSteps"), "Got: \(zh)")
        XCTAssertTrue(zh.contains("list"), "Got: \(zh)")
    }

    func test_roleRoutingHint_processRoutesToFlow() {
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("process", isEnglish: true).contains("flow")
        )
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("process", isEnglish: false).contains("flow")
        )
    }

    func test_roleRoutingHint_chronologyRoutesToTimeline() {
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("chronology", isEnglish: true).contains("timeline")
        )
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("chronology", isEnglish: false).contains("timeline")
        )
    }

    func test_roleRoutingHint_quoteRoutesToQuote() {
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("quote", isEnglish: true).contains("Quote")
        )
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("thesis", isEnglish: true).contains("Quote")
        )
    }

    func test_roleRoutingHint_comparisonRoutesToComparison() {
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("comparison", isEnglish: true).contains("Comparison")
        )
        XCTAssertTrue(
            MediaCoreViewModel.roleRoutingHint("comparison", isEnglish: false).contains("Comparison")
        )
    }

    func test_roleRoutingHint_otherFallsBackToCatalogPick() {
        // The whole point of the closed-set canonicalizer is that
        // "other" or anything weird the LLM drops in still produces
        // a non-empty, non-misleading routing line.
        let en = MediaCoreViewModel.roleRoutingHint("other", isEnglish: true)
        XCTAssertFalse(en.isEmpty)
        XCTAssertFalse(en.contains("SequenceSteps"))
        XCTAssertFalse(en.contains("Quote"))

        let zh = MediaCoreViewModel.roleRoutingHint("other", isEnglish: false)
        XCTAssertFalse(zh.isEmpty)

        // An off-schema string still produces a usable line (defensive
        // path — should never fire because callers run the role
        // through `canonicalRole` first, but if a stale persisted
        // suggestion bypasses that we still want a sensible default).
        let fallback = MediaCoreViewModel.roleRoutingHint("monologue", isEnglish: true)
        XCTAssertFalse(fallback.isEmpty)
    }

    // MARK: - BRollSuggestion → BRollSuggestionHint round-trip

    func test_suggestionHint_carriesAllNewFields() {
        // Sanity: when a suggestion has all 3 new fields populated,
        // they survive the projection into the timeline hint.
        let hint = TimelineCreativeActions.BRollSuggestionHint(
            id: UUID(),
            composedSeconds: 10.0,
            anchorDurationSeconds: 4.5,
            kind: .chart,
            prompt: "bar chart, 3 bars labelled Q1/Q2/Q3, minimal flat style",
            rationale: "speaker enumerates three quarters",
            userTitle: "Q1·Q2·Q3 chart",
            agentHint: "Q1: 12% | Q2: 18% | Q3: 24%",
            sectionRole: "data"
        )
        XCTAssertEqual(hint.userTitle, "Q1·Q2·Q3 chart")
        XCTAssertEqual(hint.agentHint, "Q1: 12% | Q2: 18% | Q3: 24%")
        XCTAssertEqual(hint.sectionRole, "data")
    }

    func test_suggestionHint_nilFieldsStayNil() {
        // Legacy path: hints constructed without the new fields keep
        // them nil so existing tests (e.g. BYOKAnimationGatesTests)
        // that only pass the original 6 args still compile and run.
        let hint = TimelineCreativeActions.BRollSuggestionHint(
            id: UUID(),
            composedSeconds: 0,
            anchorDurationSeconds: 1,
            kind: .other,
            prompt: "p",
            rationale: "r"
        )
        XCTAssertNil(hint.userTitle)
        XCTAssertNil(hint.agentHint)
        XCTAssertNil(hint.sectionRole)
    }
}

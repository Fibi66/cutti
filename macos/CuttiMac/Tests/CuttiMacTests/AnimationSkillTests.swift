import XCTest
@testable import CuttiMac

/// Smoke tests for the bundled animation skill. These are not deep
/// behavioral tests — they just verify the SwiftPM resource bundling
/// is actually wired up so the tool can read its files at runtime.
/// If `Bundle.module` plumbing breaks (e.g. someone changes
/// Package.swift's `resources:` block and the `AnimationSkill`
/// subtree gets dropped or flattened), these tests fail loudly.
///
/// In the open-source build the `Resources/AnimationSkill/` directory
/// is intentionally empty (the proprietary skill pack ships only with
/// the hosted product). Each test below first checks for the presence
/// of a marker entry and skips when absent so the OSS build runs
/// cleanly.
final class AnimationSkillTests: XCTestCase {

    private func skipIfSkillPackMissing() throws {
        let names = Set(AnimationSkill.allEntries.map { $0.name })
        try XCTSkipUnless(
            names.contains("reference/staging"),
            "Skipping: proprietary AnimationSkill pack not present in this build (open-source build ships an empty AnimationSkill directory)."
        )
    }

    func test_listEntries_includesCatalogAndReference() throws {
        try skipIfSkillPackMissing()
        let names = Set(AnimationSkill.allEntries.map { $0.name })
        // Top-level taxonomy + routing.
        XCTAssertTrue(names.contains("SKILL"),
                      "Expected bundled SKILL.md (taxonomy + routing table)")
        // Reference chapters cross-linked from catalog manuals.
        XCTAssertTrue(names.contains("reference/staging"),
                      "Expected bundled reference/staging.md")
        XCTAssertTrue(names.contains("reference/fonts"),
                      "Expected bundled reference/fonts.md")
        XCTAssertTrue(names.contains("reference/constraints"),
                      "Expected bundled reference/constraints.md")
        XCTAssertTrue(names.contains("reference/style-guide"),
                      "Expected bundled reference/style-guide.md")
        XCTAssertTrue(names.contains("reference/checklist"),
                      "Expected bundled reference/checklist.md")
        XCTAssertTrue(names.contains("reference/animation-principles"),
                      "Expected bundled reference/animation-principles.md")
        // All 12 catalog templates must be present.
        for templateID in [
            "ChapterTitle", "TitleCard", "ChatBubble", "PromptTyping",
            "SkillMeter", "CodeGen", "ContextBar", "GitHubCard",
            "TripleTap", "SequenceSteps", "Quote", "Comparison",
        ] {
            XCTAssertTrue(names.contains("catalog/\(templateID)"),
                          "Expected bundled catalog/\(templateID).md")
        }
    }

    func test_listEntries_eachHasNonEmptySummary_forCatalogAndReference() {
        let entries = AnimationSkill.allEntries
        for entry in entries
        where entry.name.hasPrefix("catalog/") || entry.name.hasPrefix("reference/") {
            XCTAssertFalse(entry.summary.isEmpty,
                           "Expected description front matter on \(entry.name)")
        }
    }

    func test_content_returnsRawMarkdown_andStripFrontMatterCleansIt() throws {
        try skipIfSkillPackMissing()
        guard let raw = AnimationSkill.content(for: "reference/staging") else {
            XCTFail("Could not load reference/staging from bundle")
            return
        }
        XCTAssertTrue(raw.hasPrefix("---"),
                      "Raw markdown should still include YAML front matter")
        let cleaned = AnimationSkill.stripFrontMatter(raw)
        XCTAssertFalse(cleaned.hasPrefix("---"),
                       "stripFrontMatter should drop the YAML block")
        XCTAssertTrue(cleaned.contains("Entrance / hold / exit thirds"),
                      "Cleaned content should still contain body text")
    }

    func test_content_isNilForUnknownName() {
        XCTAssertNil(AnimationSkill.content(for: "rules/does-not-exist"))
        XCTAssertNil(AnimationSkill.content(for: ""))
    }

    func test_readRequest_normalizesNameAndStripsExtension() {
        let r1 = AnimationSkill.ReadRequest.parse(from: ["name": "reference/staging.md"])
        XCTAssertEqual(r1?.name, "reference/staging")

        let r2 = AnimationSkill.ReadRequest.parse(from: ["name": "/reference/staging"])
        XCTAssertEqual(r2?.name, "reference/staging")

        XCTAssertNil(AnimationSkill.ReadRequest.parse(from: ["name": "   "]))
        XCTAssertNil(AnimationSkill.ReadRequest.parse(from: [:]))
    }

    /// `generate_overlay` inlines two skill files into its tool
    /// description so the agent always sees them, regardless of
    /// whether it remembered to call `read_animation_rule` first.
    /// If this regresses (empty bake, missing files, broken Bundle
    /// access), the agent silently loses house-style guidance.
    ///
    /// For cloud users the relay injects the FULL bundle (catalog
    /// manuals + reference + TSX source); this baked prompt is the
    /// BYOK fallback so the agent still has the highest-leverage
    /// rules in working memory when going direct to Azure.
    func test_bakedIntoOverlayPrompt_containsBothCriticalSections() throws {
        try skipIfSkillPackMissing()
        let baked = AnimationSkill.bakedIntoOverlayPrompt
        XCTAssertFalse(baked.isEmpty,
                       "Baked prompt must not be empty — Bundle resource lookup likely broken")
        XCTAssertTrue(baked.contains("SKILL"))
        XCTAssertTrue(baked.contains("reference/staging"))
        // Body markers from each file:
        XCTAssertTrue(baked.contains("The 12-template catalog"),
                      "SKILL section body must be inlined")
        XCTAssertTrue(baked.contains("Entrance / hold / exit thirds"),
                      "Staging section body must be inlined")
        // Front matter must be stripped.
        XCTAssertFalse(baked.contains("description: Operating manual"),
                       "YAML front matter should be stripped from baked prompt")
    }

    func test_bakedIntoOverlayPrompt_isEmbeddedInGenerateOverlayDescription() throws {
        try skipIfSkillPackMissing()
        let description = GenerateOverlayRequest.toolDefinition.function.description
        XCTAssertTrue(description.contains("Required reading: Cutti animation skill"),
                      "generate_overlay description must include the baked skill content")
        XCTAssertTrue(description.contains("The 12-template catalog"),
                      "generate_overlay description must include the SKILL taxonomy section")
    }
}

import XCTest
@testable import CuttiMac

/// Smoke tests for the bundled animation skill. These are not deep
/// behavioral tests — they just verify the SwiftPM resource bundling
/// is actually wired up so the tool can read its files at runtime.
/// If `Bundle.module` plumbing breaks (e.g. someone changes
/// Package.swift's `resources:` block and the `AnimationSkill`
/// subtree gets dropped or flattened), these tests fail loudly.
final class AnimationSkillTests: XCTestCase {

    func test_listEntries_includesCuttiSpecificRules() {
        let names = Set(AnimationSkill.allEntries.map { $0.name })
        XCTAssertTrue(names.contains("rules/cutti-staging"),
                      "Expected bundled rules/cutti-staging.md")
        XCTAssertTrue(names.contains("rules/cutti-checklist"),
                      "Expected bundled rules/cutti-checklist.md")
        XCTAssertTrue(names.contains("rules/cutti-templates"),
                      "Expected bundled rules/cutti-templates.md")
        XCTAssertTrue(names.contains("rules/cutti-constraints"),
                      "Expected bundled rules/cutti-constraints.md")
        XCTAssertTrue(names.contains("rules/cutti-fonts"),
                      "Expected bundled rules/cutti-fonts.md")
        // The generic skill files should also have been copied.
        XCTAssertTrue(names.contains("SKILL"),
                      "Expected bundled SKILL.md")
        XCTAssertTrue(names.contains("style-guide/aesthetic"),
                      "Expected bundled style-guide/aesthetic.md")
        XCTAssertTrue(names.contains("rules/animations"),
                      "Expected bundled rules/animations.md")
    }

    func test_listEntries_eachHasNonEmptySummary_forCuttiRules() {
        let entries = AnimationSkill.allEntries
        for entry in entries where entry.name.hasPrefix("rules/cutti-") {
            XCTAssertFalse(entry.summary.isEmpty,
                           "Expected description front matter on \(entry.name)")
        }
    }

    func test_content_returnsRawMarkdown_andStripFrontMatterCleansIt() {
        guard let raw = AnimationSkill.content(for: "rules/cutti-staging") else {
            XCTFail("Could not load rules/cutti-staging from bundle")
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
        let r1 = AnimationSkill.ReadRequest.parse(from: ["name": "rules/cutti-staging.md"])
        XCTAssertEqual(r1?.name, "rules/cutti-staging")

        let r2 = AnimationSkill.ReadRequest.parse(from: ["name": "/rules/cutti-staging"])
        XCTAssertEqual(r2?.name, "rules/cutti-staging")

        XCTAssertNil(AnimationSkill.ReadRequest.parse(from: ["name": "   "]))
        XCTAssertNil(AnimationSkill.ReadRequest.parse(from: [:]))
    }

    /// `generate_overlay` inlines two skill files into its tool
    /// description so the agent always sees them, regardless of
    /// whether it remembered to call `read_animation_rule` first.
    /// If this regresses (empty bake, missing files, broken Bundle
    /// access), the agent silently loses house-style guidance.
    func test_bakedIntoOverlayPrompt_containsBothCriticalSections() {
        let baked = AnimationSkill.bakedIntoOverlayPrompt
        XCTAssertFalse(baked.isEmpty,
                       "Baked prompt must not be empty — Bundle resource lookup likely broken")
        XCTAssertTrue(baked.contains("rules/cutti-templates"))
        XCTAssertTrue(baked.contains("rules/cutti-staging"))
        // Body markers from each file:
        XCTAssertTrue(baked.contains("Three house styles"),
                      "Templates section body must be inlined")
        XCTAssertTrue(baked.contains("Entrance / hold / exit thirds"),
                      "Staging section body must be inlined")
        // Front matter must be stripped.
        XCTAssertFalse(baked.contains("description: Cutti's shipped overlay templates"),
                       "YAML front matter should be stripped from baked prompt")
    }

    func test_bakedIntoOverlayPrompt_isEmbeddedInGenerateOverlayDescription() {
        let description = GenerateOverlayRequest.toolDefinition.function.description
        XCTAssertTrue(description.contains("Required reading: Cutti animation skill"),
                      "generate_overlay description must include the baked skill content")
        XCTAssertTrue(description.contains("Three house styles"),
                      "generate_overlay description must include the templates section")
    }
}

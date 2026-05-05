import XCTest
@testable import CuttiMac

/// Tests for the `gen.hook` workflow preset (PR 6 of the opening-hook
/// feature). The preset surfaces the AI-driven hook discovery flow at
/// the ⚡ menu and the ⌘⇧3 shortcut: clicking it seeds a canonical
/// prompt that asks the agent to call `score_hook_candidates` then
/// `add_hook_teaser` with explicit user confirmation between the two.
final class AgentWorkflowPresetHookTests: XCTestCase {

    // MARK: - Catalog visibility

    func test_hookPreset_isPresentInCatalog() {
        let preset = AgentWorkflowPreset.all.first { $0.id == "gen.hook" }
        XCTAssertNotNil(preset, "gen.hook preset must be registered")
    }

    func test_hookPreset_isInGenerativeGroup() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }) else {
            return XCTFail("gen.hook preset missing")
        }
        XCTAssertEqual(preset.group, .generative)
    }

    func test_hookPreset_advertisesShortcutLabel() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }) else {
            return XCTFail("gen.hook preset missing")
        }
        XCTAssertEqual(preset.shortcutLabel, "⌘⇧3",
                       "gen.hook should claim the ⌘⇧3 shortcut so the menu hints match the actual binding")
    }

    func test_hookPreset_isVisibleToBothCloudAndBYOK() {
        // The hook flow uses score_hook_candidates (local stage-1 + LLM
        // stage-2 via the user's own provider) and add_hook_teaser (pure
        // local). It does NOT depend on the proprietary Remotion
        // animation pipeline, so BYOK users must see it too — otherwise
        // open-source builds lose the feature entirely.
        let cloudVisible = AgentWorkflowPreset.available(for: .cuttiCloud).contains { $0.id == "gen.hook" }
        let byokVisible = AgentWorkflowPreset.available(for: .custom).contains { $0.id == "gen.hook" }
        XCTAssertTrue(cloudVisible, "cloud subscribers must see gen.hook")
        XCTAssertTrue(byokVisible, "BYOK / open-source users must see gen.hook")
        XCTAssertFalse(AgentWorkflowPreset.cloudOnlyPresetIDs.contains("gen.hook"),
                       "gen.hook must not be in cloudOnlyPresetIDs")
    }

    // MARK: - Seed prompt content

    /// The seed prompt must drive the agent through the score → confirm
    /// → insert flow. Drift in this prompt has been the leading cause
    /// of past LLM regressions in similar presets, so we lock the
    /// load-bearing tokens in.
    func test_hookPreset_seedPromptMentionsBothTools() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }),
              case .seedPrompt(let text) = preset.action else {
            return XCTFail("gen.hook preset must use .seedPrompt")
        }
        XCTAssertTrue(text.contains("score_hook_candidates"),
                      "seed prompt must reference score_hook_candidates")
        XCTAssertTrue(text.contains("add_hook_teaser"),
                      "seed prompt must reference add_hook_teaser")
    }

    func test_hookPreset_seedPromptForcesUserConfirmation() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }),
              case .seedPrompt(let text) = preset.action else {
            return XCTFail("gen.hook preset must use .seedPrompt")
        }
        // L() returns the localized prompt — Chinese-locale test runs
        // see the zh-Hans translation, English-locale runs see English.
        // Both must encode the "wait for the user before inserting"
        // contract. We accept either set of load-bearing tokens.
        let lower = text.lowercased()
        let englishMatch = lower.contains("confirm") || lower.contains("wait for") || lower.contains("not pick or apply automatically")
        let chineseMatch = text.contains("我确认") || text.contains("等我回答") || text.contains("不要自己替我挑")
        XCTAssertTrue(englishMatch || chineseMatch,
                      "seed prompt must instruct the agent to wait for user confirmation between score and insert (got: \(text))")
    }

    func test_hookPreset_seedPromptCarriesInsertParameters() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }),
              case .seedPrompt(let text) = preset.action else {
            return XCTFail("gen.hook preset must use .seedPrompt")
        }
        XCTAssertTrue(text.contains("source_video_id"),
                      "seed prompt must list source_video_id so the agent knows what to pull from the candidate")
        XCTAssertTrue(text.contains("source_start"),
                      "seed prompt must list source_start")
        XCTAssertTrue(text.contains("source_end"),
                      "seed prompt must list source_end")
    }

    // MARK: - Group ordering

    /// Soft-locks the menu order: the hook preset should appear in the
    /// Generative group above the title-card preset (which is
    /// cloud-only and lower-frequency). Drift here is cosmetic, but the
    /// test serves as a tripwire if someone reshuffles the catalog.
    func test_hookPreset_appearsBeforeOverlayTitlesInGenerativeGroup() {
        let generative = AgentWorkflowPreset.byGroup()
            .first { $0.0 == .generative }?.1 ?? []
        let hookIdx = generative.firstIndex { $0.id == "gen.hook" }
        let overlayIdx = generative.firstIndex { $0.id == "gen.overlayTitles" }
        XCTAssertNotNil(hookIdx)
        XCTAssertNotNil(overlayIdx)
        if let h = hookIdx, let o = overlayIdx {
            XCTAssertLessThan(h, o, "gen.hook should sit above gen.overlayTitles in the Generative group")
        }
    }
}

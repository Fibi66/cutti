import XCTest
@testable import CuttiMac

/// Tests for `AgentWorkflowPreset.seedPromptTrigger(forceFillComposer:)`,
/// the single source of truth for how a workflow preset's plain-click /
/// keyboard-shortcut / context-menu invocation routes between
/// fill-the-composer (the user edits before sending) and auto-send
/// (the chat history shows the preset's title as a clean action chip
/// instead of the verbose internal prompt).
///
/// The redesign motivation: workflow presets like `gen.hook` and
/// `smart.fillers` used to fill the chat composer with a long
/// scaffolded instruction that exposed internal tool names
/// (`score_hook_candidates`, `add_hook_teaser`). The user complained
/// that quick AI actions shouldn't expose the prompt — they should
/// just execute and show "what was triggered" in the UI. The router
/// implements that policy while preserving an "Edit before sending"
/// escape hatch (Option-click / context menu) for users who do want
/// to peek or tweak the prompt.
final class AgentWorkflowPresetRoutingTests: XCTestCase {

    // MARK: - Pipeline presets are not seedPrompt actions

    func test_pipelinePresets_returnNil() {
        let pipelineIDs = [
            "smart.full",            // .runFullAnalysis
            "smart.trimPauses",      // .runTrimPauses
            "smart.transcriptCleanup", // .runTranscriptCleanup
            "smart.suggestBRoll",    // .runSuggestBRoll
            "gen.chapters",          // .runChapterGeneration
            "vision.autoPiP",        // .runAutoPiP
            "gen.image",             // .openImageGen
        ]
        for id in pipelineIDs {
            guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == id }) else {
                return XCTFail("pipeline preset \(id) missing from catalog")
            }
            XCTAssertNil(
                preset.seedPromptTrigger(),
                "\(id) is a pipeline action — it must return nil so the button dispatches the dedicated onRun* callback instead of the prompt path"
            )
            XCTAssertNil(
                preset.seedPromptTrigger(forceFillComposer: true),
                "\(id) must return nil even when forceFillComposer is set — pipeline actions never go through the composer"
            )
        }
    }

    // MARK: - Canned seedPrompt presets auto-send by default

    /// The 13 canned seedPrompt presets — none of them have
    /// `<fill in ...>` placeholders, so plain click should auto-send
    /// them (with the localized preset title displayed in the chat
    /// bubble) instead of dropping the verbose prompt into the
    /// composer.
    func test_cannedSeedPrompts_autoSendOnPlainClick() {
        let cannedIDs = [
            "smart.fillers",
            "speaker.detect",
            "vision.empty",
            "vision.black",
            "gen.broll",
            "gen.title",
            "gen.hook",
            "gen.overlayTitles",
            "gen.summary",
            "subtitle.bilingual.zh-en",
            "subtitle.translate.en",
            "subtitle.translate.zh",
        ]
        for id in cannedIDs {
            guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == id }) else {
                return XCTFail("canned preset \(id) missing from catalog")
            }
            XCTAssertFalse(
                preset.requiresInputBeforeSubmit,
                "\(id) has no <fill in ...> placeholder — it must NOT be flagged requiresInputBeforeSubmit"
            )
            switch preset.seedPromptTrigger() {
            case .autoSend(let prompt, let displayLabel):
                XCTAssertFalse(
                    prompt.isEmpty,
                    "\(id) must auto-send a non-empty prompt"
                )
                XCTAssertFalse(
                    displayLabel.isEmpty,
                    "\(id) must auto-send with a non-empty display label so the chat bubble has something to render instead of the prompt"
                )
            case .fillComposer:
                XCTFail("\(id) is a canned prompt — plain click must auto-send, not fill the composer")
            case .none:
                XCTFail("\(id) is a seedPrompt — must not return nil")
            }
        }
    }

    /// Canned seedPrompt presets must surface the preset's localized
    /// title as the chat-bubble label. This is what fixes the bug
    /// the user complained about — instead of showing the raw
    /// `score_hook_candidates ...` prompt, the bubble shows
    /// "Pick an opening hook" / "挑选开场金句" depending on locale.
    func test_cannedSeedPrompts_useLocalizedTitleAsDisplayLabel() {
        guard let hook = AgentWorkflowPreset.all.first(where: { $0.id == "gen.hook" }) else {
            return XCTFail("gen.hook missing")
        }
        guard case .autoSend(_, let displayLabel) = hook.seedPromptTrigger() else {
            return XCTFail("gen.hook must auto-send")
        }
        XCTAssertEqual(
            displayLabel,
            L(hook.title),
            "displayLabel must be the localized preset title — that's how the chat bubble avoids showing the raw scaffolded prompt"
        )
    }

    /// The displayLabel must NOT carry any of the load-bearing internal
    /// tool tokens — that would defeat the whole point of the
    /// redesign (the user complained about seeing tool names in chat).
    func test_cannedSeedPrompts_displayLabelDoesNotLeakInternalTokens() {
        let leakyTokens = [
            "score_hook_candidates",
            "add_hook_teaser",
            "source_video_id",
            "source_start",
            "source_end",
            "generate_overlay",
            "template_id",
            "props_json",
            "<fill in",
            "<填入",
        ]
        for preset in AgentWorkflowPreset.all {
            guard case .autoSend(_, let displayLabel) = preset.seedPromptTrigger() else { continue }
            for token in leakyTokens {
                XCTAssertFalse(
                    displayLabel.contains(token),
                    "\(preset.id)'s display label \(displayLabel.debugDescription) leaks internal token \(token) — the chat bubble must show a clean action chip, not the raw prompt"
                )
            }
        }
    }

    // MARK: - Placeholder presets always fill the composer

    /// The 3 placeholder seedPrompt presets contain `<fill in ...>` /
    /// `<填入...>` tokens that the user must replace before sending.
    /// Auto-sending one of these would ship the literal placeholder
    /// to the LLM, which is useless. They must always route through
    /// the composer regardless of how they're invoked.
    func test_placeholderPresets_alwaysFillComposer() {
        let placeholderIDs = [
            "speaker.mute",            // <fill in which speaker>
            "speaker.list",            // <fill in which speaker>
            "subtitle.translate.custom", // <fill in target language>
        ]
        for id in placeholderIDs {
            guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == id }) else {
                return XCTFail("placeholder preset \(id) missing from catalog")
            }
            XCTAssertTrue(
                preset.requiresInputBeforeSubmit,
                "\(id) has a <fill in ...> placeholder — it MUST be flagged requiresInputBeforeSubmit"
            )
            switch preset.seedPromptTrigger() {
            case .fillComposer(let prompt):
                XCTAssertFalse(prompt.isEmpty, "\(id) must fill the composer with a non-empty prompt")
            case .autoSend:
                XCTFail("\(id) has a placeholder — plain click MUST fill the composer, not auto-send")
            case .none:
                XCTFail("\(id) is a seedPrompt — must not return nil")
            }
            // forceFillComposer must keep the same behavior — there's
            // no "auto-send anyway" override for placeholder presets.
            switch preset.seedPromptTrigger(forceFillComposer: true) {
            case .fillComposer:
                break
            default:
                XCTFail("\(id) must always route to the composer regardless of forceFillComposer")
            }
        }
    }

    /// Cross-check: every preset whose canonical prompt contains a
    /// localizable `<fill in` / `<填入` placeholder MUST be flagged
    /// `requiresInputBeforeSubmit`. Catches the case where someone
    /// adds a new placeholder preset but forgets to set the flag —
    /// the redesign would silently ship the placeholder to the LLM
    /// otherwise.
    func test_everyPresetWithPlaceholderTextIsFlagged() {
        for preset in AgentWorkflowPreset.all {
            guard case .seedPrompt(let text) = preset.action else { continue }
            let hasPlaceholder = text.contains("<fill in") || text.contains("<填入")
            if hasPlaceholder {
                XCTAssertTrue(
                    preset.requiresInputBeforeSubmit,
                    "\(preset.id)'s prompt contains a placeholder but is not flagged requiresInputBeforeSubmit — auto-sending it would ship the literal placeholder text to the LLM"
                )
            } else {
                XCTAssertFalse(
                    preset.requiresInputBeforeSubmit,
                    "\(preset.id)'s prompt has no placeholder yet it's flagged requiresInputBeforeSubmit — that would force the composer for no reason"
                )
            }
        }
    }

    // MARK: - Force-fill (Option-click / "Edit before sending")

    /// Option-click and the context-menu "Edit before sending" entry
    /// pass `forceFillComposer: true`. Canned seedPrompts must
    /// honor it — that's the user's escape hatch to peek or tweak a
    /// prompt that would otherwise auto-send.
    func test_cannedSeedPrompts_forceFillComposer_routesToComposer() {
        guard let preset = AgentWorkflowPreset.all.first(where: { $0.id == "smart.fillers" }) else {
            return XCTFail("smart.fillers missing")
        }
        switch preset.seedPromptTrigger(forceFillComposer: true) {
        case .fillComposer(let prompt):
            XCTAssertTrue(prompt.contains("filler") || prompt.contains("uh") || prompt.contains("废话") || prompt.contains("语气词"),
                          "forced composer-fill must carry the canonical filler prompt")
        case .autoSend:
            XCTFail("forceFillComposer must route to .fillComposer even for canned prompts")
        case .none:
            XCTFail("smart.fillers is a seedPrompt — must not return nil")
        }
    }

    /// All 16 seedPrompt presets together: the helper must classify
    /// every one of them. If a new preset is added without test
    /// coverage, this catch-all asserts the helper still routes it
    /// (success) rather than returning nil (would crash the
    /// invoke() switch silently).
    func test_everySeedPromptPresetClassifies() {
        let seedPromptPresets = AgentWorkflowPreset.all.filter {
            if case .seedPrompt = $0.action { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(
            seedPromptPresets.count,
            13,
            "regression guard: catalog must include the canned + placeholder seedPrompts the redesign was built around"
        )
        for preset in seedPromptPresets {
            XCTAssertNotNil(
                preset.seedPromptTrigger(),
                "every seedPrompt preset must classify under the routing helper — \(preset.id) returned nil"
            )
        }
    }
}

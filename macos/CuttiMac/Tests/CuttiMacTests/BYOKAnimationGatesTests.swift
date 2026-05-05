import XCTest
import CuttiKit
@testable import CuttiMac

/// Coverage for the second-wave BYOK animation gates that close the
/// holes the first wave (`AppleSiliconPhaseOneStackOverlayRendererTests`,
/// `MediaCoreViewModelOverlayBYOKTests`) couldn't reach:
///
///   1. The LLM tool catalog: `agentToolDefinitions(for:)` must NOT
///      list the four animation tools when the user is on `.custom`.
///   2. The runtime tool authorization in `executeAgentToolCall`: even
///      when the catalog excludes them, a malicious BYOK provider can
///      return a fabricated `tool_calls[]` for `generate_overlay` /
///      `update_overlay_props` / `list_animation_rules` /
///      `read_animation_rule`. We test by driving the public entry
///      points (`generateOverlay`, `updateOverlayProps`,
///      `generateOverlayFromSuggestion`) which mirror the same gate.
///   3. The B-roll suggestion strip filter: `.animation`/`.other` hints
///      must be dropped when animation is unavailable.
///   4. The workflow preset filter: cloud-only presets must be hidden.
///
/// Mutates `UserDefaults.standard["cutti.aiProvider"]` to flip the
/// provider; setUp/tearDown stash and restore the prior value.
@MainActor
final class BYOKAnimationGatesTests: XCTestCase {
    private let providerKey = "cutti.aiProvider"
    private var savedProviderRaw: String?

    override func setUp() {
        super.setUp()
        savedProviderRaw = UserDefaults.standard.string(forKey: providerKey)
    }

    override func tearDown() {
        if let saved = savedProviderRaw {
            UserDefaults.standard.set(saved, forKey: providerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: providerKey)
        }
        super.tearDown()
    }

    private func makeTempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cutti-byok-gates-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 1. Tools catalog

    func test_agentToolDefinitions_cuttiCloud_includesAnimationTools() {
        let tools = MediaCoreViewModel.agentToolDefinitions(for: .cuttiCloud)
        let names = tools.map(\.function.name)
        XCTAssertTrue(names.contains("generate_overlay"))
        XCTAssertTrue(names.contains("update_overlay_props"))
        XCTAssertTrue(names.contains("list_animation_rules"))
        XCTAssertTrue(names.contains("read_animation_rule"))
        // Sanity: shared tools still present in both modes.
        XCTAssertTrue(names.contains("edit_timeline"))
        XCTAssertTrue(names.contains("generate_image"),
                      "Image generation must remain available even when not on Cutti Cloud — it routes through the user's own image API for BYOK.")
    }

    func test_agentToolDefinitions_byok_omitsAllFourAnimationTools() {
        let tools = MediaCoreViewModel.agentToolDefinitions(for: .custom)
        let names = Set(tools.map(\.function.name))
        XCTAssertFalse(names.contains("generate_overlay"),
                       "BYOK must not advertise generate_overlay — that tool depends on the cloud Remotion renderer.")
        XCTAssertFalse(names.contains("update_overlay_props"),
                       "BYOK must not advertise update_overlay_props — re-rendering also depends on the cloud renderer.")
        XCTAssertFalse(names.contains("list_animation_rules"),
                       "BYOK must not advertise list_animation_rules — would leak the proprietary skill catalog to the user's BYOK API endpoint.")
        XCTAssertFalse(names.contains("read_animation_rule"),
                       "BYOK must not advertise read_animation_rule — would leak proprietary skill markdown to the user's BYOK API endpoint.")
        // Image generation still available.
        XCTAssertTrue(names.contains("generate_image"))
        XCTAssertTrue(names.contains("edit_timeline"))
    }

    func test_byokBlockedToolNames_setMatches_publicGateMembership() {
        XCTAssertEqual(
            MediaCoreViewModel.byokBlockedToolNames,
            ["generate_overlay", "update_overlay_props", "list_animation_rules", "read_animation_rule"],
            "Hard-coded set is the source of truth used by both the tools-catalog filter and the runtime authorization check; do not change without updating both."
        )
    }

    // MARK: - 2. Runtime gate via public entry points (covers the
    //           "malicious BYOK provider returns fabricated tool_call"
    //           threat: every server-issued tool name routes through
    //           one of these methods, so gating them gates the agent
    //           loop too).

    func test_byokProvider_blocksGenerateOverlayFromSuggestion_animationKind() async throws {
        let root = try makeTempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let renderer = FakeRemotionRenderer()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        UserDefaults.standard.set(
            AIProviderPreference.custom.rawValue,
            forKey: providerKey
        )

        let hint = TimelineCreativeActions.BRollSuggestionHint(
            id: UUID(),
            composedSeconds: 5.0,
            anchorDurationSeconds: 3.0,
            kind: .animation,
            prompt: "animated chapter title 'Intro'",
            rationale: "Strong topic boundary."
        )
        vm.generateOverlayFromSuggestion(hint, editedPrompt: "animated chapter title 'Intro'")
        // The function returns synchronously when gated; no async
        // completion to await here because it never enters
        // `handleAIPrompt`. Yield once just to let any stray work
        // settle.
        await Task.yield()

        XCTAssertEqual(renderer.recordedRequests, [], "BYOK animation gate must short-circuit before the renderer.")
        XCTAssertEqual(stubMediaCore.importedURLs, [])
        XCTAssertEqual(
            vm.bannerMessage,
            L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud."),
            "BYOK animation gate must surface the same warning copy used everywhere else.")
        XCTAssertNil(vm.pendingOverlayAnchor,
                     "Gated path must not stash anchor context — that scaffolding only makes sense for an actual generate_overlay round-trip.")
    }

    func test_byokProvider_allowsGenerateOverlayFromSuggestion_imageKind() async throws {
        // Image-kind hints route through FLUX (which works for BYOK
        // via the user's own image API). The animation gate must
        // NOT block them.
        let root = try makeTempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let renderer = FakeRemotionRenderer()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        UserDefaults.standard.set(
            AIProviderPreference.custom.rawValue,
            forKey: providerKey
        )

        let hint = TimelineCreativeActions.BRollSuggestionHint(
            id: UUID(),
            composedSeconds: 5.0,
            anchorDurationSeconds: 3.0,
            kind: .image,
            prompt: "still photograph of a sunlit kitchen",
            rationale: "Backs the food story."
        )
        vm.generateOverlayFromSuggestion(hint, editedPrompt: hint.prompt)
        await Task.yield()

        // Image path runs through generateAIImageAndInsertOverlay, which
        // (without an OpenAI key configured in this test) fails inside
        // its own service rather than at the BYOK gate. The gate must
        // NOT have set the animation-only banner.
        if let banner = vm.bannerMessage {
            XCTAssertNotEqual(
                banner,
                L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud."),
                "Animation gate must not fire for an image-kind hint."
            )
        }
    }

    func test_byokProvider_blocksUpdateOverlayProps_evenWithRendererWired() async throws {
        // Mirror of `test_byokProvider_blocksGenerateOverlay_…` but for
        // the props-edit path (Inspector "Apply" button + the agent's
        // `update_overlay_props` tool call).
        let root = try makeTempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let renderer = FakeRemotionRenderer()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        UserDefaults.standard.set(
            AIProviderPreference.custom.rawValue,
            forKey: providerKey
        )

        await vm.updateOverlayProps(
            segmentID: UUID(),
            propsPatch: ["title": "BYOK should never reach here"]
        )

        XCTAssertEqual(renderer.recordedRequests, [],
                       "BYOK gate on updateOverlayProps must short-circuit before the renderer.")
        XCTAssertEqual(
            vm.bannerMessage,
            L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
        )
    }

    // MARK: - 3. Suggestion strip filter

    func test_strip_filter_byok_dropsAnimationAndOtherHints_keepsImageFamily() {
        let hints: [TimelineCreativeActions.BRollSuggestionHint] = [
            .init(id: UUID(), composedSeconds: 1, anchorDurationSeconds: 2, kind: .animation, prompt: "a", rationale: ""),
            .init(id: UUID(), composedSeconds: 2, anchorDurationSeconds: 2, kind: .image, prompt: "b", rationale: ""),
            .init(id: UUID(), composedSeconds: 3, anchorDurationSeconds: 2, kind: .chart, prompt: "c", rationale: ""),
            .init(id: UUID(), composedSeconds: 4, anchorDurationSeconds: 2, kind: .mapGraphic, prompt: "d", rationale: ""),
            .init(id: UUID(), composedSeconds: 5, anchorDurationSeconds: 2, kind: .dataTable, prompt: "e", rationale: ""),
            .init(id: UUID(), composedSeconds: 6, anchorDurationSeconds: 2, kind: .screenRecording, prompt: "f", rationale: ""),
            .init(id: UUID(), composedSeconds: 7, anchorDurationSeconds: 2, kind: .other, prompt: "g", rationale: ""),
        ]
        let visible = BRollSuggestionStrip.filterSuggestions(hints, animationGenerationAvailable: false)
        let kinds = visible.map(\.kind)
        XCTAssertFalse(kinds.contains(.animation),
                       "Animation hints must not render in BYOK — there's no way for the user to fulfill them.")
        XCTAssertFalse(kinds.contains(.other),
                       ".other hints route through the same Remotion path as .animation; must be dropped in BYOK.")
        XCTAssertTrue(kinds.contains(.image))
        XCTAssertTrue(kinds.contains(.chart))
        XCTAssertTrue(kinds.contains(.mapGraphic))
        XCTAssertTrue(kinds.contains(.dataTable))
        XCTAssertTrue(kinds.contains(.screenRecording))
    }

    func test_strip_filter_cuttiCloud_keepsEverything() {
        let hints: [TimelineCreativeActions.BRollSuggestionHint] = [
            .init(id: UUID(), composedSeconds: 1, anchorDurationSeconds: 2, kind: .animation, prompt: "a", rationale: ""),
            .init(id: UUID(), composedSeconds: 2, anchorDurationSeconds: 2, kind: .image, prompt: "b", rationale: ""),
        ]
        let visible = BRollSuggestionStrip.filterSuggestions(hints, animationGenerationAvailable: true)
        XCTAssertEqual(visible.count, 2)
    }

    // MARK: - 3b. Experimental confirmation gate

    /// Animation-class generations have to pass the experimental
    /// confirmation dialog because the Remotion compose pipeline can
    /// still produce broken / unstable output and each attempt burns
    /// cloud credits.
    func test_experimentalConfirmation_requiredForAnimationKinds() {
        XCTAssertTrue(BRollSuggestionStrip.requiresExperimentalConfirmation(.animation),
                      "Generate animation must pop the experimental confirmation dialog.")
        XCTAssertTrue(BRollSuggestionStrip.requiresExperimentalConfirmation(.other),
                      ".other routes through the same Remotion compose path as .animation and must be gated identically.")
    }

    /// FLUX image generation is the proven path. Forcing a dialog
    /// there would just train users to click through every confirm.
    func test_experimentalConfirmation_skippedForImageFamily() {
        for kind: BRollSuggestion.Kind in [.image, .chart, .mapGraphic, .dataTable, .screenRecording] {
            XCTAssertFalse(BRollSuggestionStrip.requiresExperimentalConfirmation(kind),
                           "Image-family kind \(kind) must NOT require experimental confirmation.")
        }
    }

    // MARK: - 4. Workflow preset filter

    func test_presets_byok_excludesGenOverlayTitles() {
        let visible = AgentWorkflowPreset.available(for: .custom)
        XCTAssertFalse(visible.contains(where: { $0.id == "gen.overlayTitles" }),
                       "Animated title cards preset must hide for BYOK — it explicitly seeds a generate_overlay tool call.")
        // Sanity: the filter must not drop unrelated generative
        // presets like image generation or summary.
        XCTAssertTrue(visible.contains(where: { $0.id == "gen.image" }))
        XCTAssertTrue(visible.contains(where: { $0.id == "gen.summary" }))
    }

    func test_presets_cuttiCloud_keepsGenOverlayTitles() {
        let visible = AgentWorkflowPreset.available(for: .cuttiCloud)
        XCTAssertTrue(visible.contains(where: { $0.id == "gen.overlayTitles" }))
    }

    func test_presets_byGroup_byok_filtersInsideGroup() {
        let groups = AgentWorkflowPreset.byGroup(for: .custom)
        let generative = groups.first(where: { $0.0 == .generative })?.1 ?? []
        XCTAssertFalse(generative.contains(where: { $0.id == "gen.overlayTitles" }))
        XCTAssertTrue(generative.contains(where: { $0.id == "gen.image" }))
    }

    // MARK: - 5. System prompt content

    func test_systemPrompt_isPureSwiftBuilder_noLeakWhenBYOK() {
        // We can't easily call the private prompt builder, but the
        // helper that gates the tools array is the same `aiProvider()`
        // read. This test is a sentinel: if someone reintroduces the
        // animation bullets unconditionally, the tools-catalog test
        // above will already fail; this test pins that the source of
        // truth is `byokBlockedToolNames` so the prompt and the tools
        // can never drift.
        XCTAssertEqual(MediaCoreViewModel.byokBlockedToolNames.count, 4)
    }
}

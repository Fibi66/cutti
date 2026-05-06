import Foundation

/// A built-in AI workflow the user can trigger from the chat composer's
/// `⚡` button (or `/` slash command).
///
/// Two kinds of presets:
///
/// 1. **Pipeline presets** (`.pipeline`) — bypass the LLM chat loop and
///    call a deterministic pipeline directly (e.g. the 4-pass
///    FullAnalysisPipeline). Kind is hard-wired on the VM side.
///
/// 2. **Prompt presets** (`.prompt`) — inject a canonical Chinese prompt
///    into the composer so the Agent loop processes it like a normal
///    user request. The user can still edit before sending.
///
/// Only AI-powered features belong in here (LLM or ML). Deterministic
/// audio / timeline ops (loudness norm, crossfade, etc.) are NOT listed
/// and stay accessible via natural-language chat.
struct AgentWorkflowPreset: Identifiable, Hashable {
    enum Action: Hashable {
        /// Run the built-in full analysis pipeline (transcribe → 4-pass
        /// LLM cleanup). Equivalent to the old "Start AI analysis" CTA.
        case runFullAnalysis
        /// Local-only: transcribe + silence-detect + trim, then keep
        /// every spoken segment. Drops inter-segment pauses but cuts no
        /// content. Skips all LLM passes, so it's fast and free.
        case runTrimPauses
        /// Run only the 4-pass LLM cleanup on the clip (initial
        /// keep/cut + restart-duplicate + rewording-equivalence +
        /// completeness review). Deletes废话 / 重复 / 残句 but does
        /// not suggest B-roll afterward.
        case runTranscriptCleanup
        /// Run only the 1-pass B-roll / animation suggestion service
        /// against the current kept transcript. Shows visual-aid
        /// markers on the timeline.
        case runSuggestBRoll
        /// Run the chapter-bar generation pass on the current edited
        /// timeline. Stores chapters on the snapshot and pushes a
        /// revision so the previous chapter list (if any) restores via
        /// undo.
        case runChapterGeneration
        /// Run the on-device Auto-PiP analyzer on every overlay clip
        /// and apply the suggested Picture-in-Picture layout to the
        /// ones that look like presenter cams.
        case runAutoPiP
        /// Open the freeform "Generate AI image" sheet (FLUX). The
        /// sheet owns the prompt + size UI; this preset just opens it.
        case openImageGen
        /// Run a canonical prompt against the agent loop. Plain click /
        /// shortcut auto-sends the prompt and the chat history bubble
        /// displays the preset's `title` instead of the verbose
        /// instruction (the LLM still receives the full text via
        /// `EditorChatMessage.content`). The escape hatch for users who
        /// want to peek or tweak the prompt before it goes out is
        /// Option-click / context-menu "Edit before sending", which
        /// fills the composer instead.
        ///
        /// Presets whose prompt contains a `<fill in ...>` placeholder
        /// must opt out of the auto-send default by setting
        /// `requiresInputBeforeSubmit: true` on the preset — those
        /// always fill the composer regardless of how they're invoked.
        case seedPrompt(String)
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let group: Group
    let action: Action
    /// Optional keyboard shortcut label (e.g. "⌘⇧1"). Informational —
    /// the actual binding lives in the menu's `.keyboardShortcut`.
    let shortcutLabel: String?
    /// `true` for seedPrompt presets whose canonical text contains a
    /// `<fill in ...>` placeholder the user must edit before sending
    /// (e.g. "mute every line spoken by <fill in which speaker>").
    /// Plain click on these always fills the composer rather than
    /// auto-sending — anything else would ship the literal placeholder
    /// to the LLM.
    let requiresInputBeforeSubmit: Bool

    init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        group: Group,
        action: Action,
        shortcutLabel: String? = nil,
        requiresInputBeforeSubmit: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.group = group
        self.action = action
        self.shortcutLabel = shortcutLabel
        self.requiresInputBeforeSubmit = requiresInputBeforeSubmit
    }

    enum Group: String, CaseIterable {
        case smartCut = "Smart cut"
        case speaker = "Speaker"
        case vision = "Vision"
        case subtitles = "Subtitles"
        case generative = "Generative"
    }

    /// Canonical prompts for subtitle / translation workflows, reused by
    /// both the AI workflow menu and the Timeline's S-lane context menu
    /// so the two entry points stay semantically identical.
    ///
    /// Wrapped in `L()` so that Chinese-locale users get a Chinese prompt
    /// pre-filled in the chat composer (the LLM understands both, but
    /// the user often wants to tweak the prompt before sending — they
    /// shouldn't have to read English to do that).
    enum SubtitlePrompts {
        static var bilingualZhEn: String {
            L("Add bilingual subtitles. Detect the source language of the current subtitles: if it is Chinese, translate every cue to English; otherwise translate every cue to Simplified Chinese. Then enable bilingual style with the translation rendered below the original at 75% size.")
        }

        static var translateToEnglish: String {
            L("Translate every subtitle cue to English, then enable bilingual style with the English translation below the original at 75% size.")
        }

        static var translateToChinese: String {
            L("Translate every subtitle cue to Simplified Chinese (zh-Hans), then enable bilingual style with the Chinese translation below the original at 75% size.")
        }

        static var translateToCustom: String {
            L("Translate every subtitle cue to <fill in target language>, then enable bilingual style with the translation below the original at 75% size.")
        }
    }

    static var all: [AgentWorkflowPreset] {
        [
        // MARK: Smart cutting
        .init(
            id: "smart.full",
            title: "One-click first cut",
            subtitle: "Workflow: trim pauses → transcript cleanup → suggest B-roll",
            systemImage: "sparkles",
            group: .smartCut,
            action: .runFullAnalysis,
            shortcutLabel: "⌘⇧1"
        ),
        .init(
            id: "smart.trimPauses",
            title: "Trim pauses only",
            subtitle: "Remove silent gaps. Local — no AI credits, keeps every word.",
            systemImage: "waveform.path",
            group: .smartCut,
            action: .runTrimPauses
        ),
        .init(
            id: "smart.transcriptCleanup",
            title: "Transcript cleanup",
            subtitle: "4-pass AI review: delete restarts, rewordings, half-finished sentences.",
            systemImage: "text.badge.minus",
            group: .smartCut,
            action: .runTranscriptCleanup
        ),
        .init(
            id: "smart.suggestBRoll",
            title: "Suggest B-roll & animations",
            subtitle: "AI marks moments where a visual, chart, or animation would help.",
            systemImage: "sparkles.rectangle.stack",
            group: .smartCut,
            action: .runSuggestBRoll
        ),
        .init(
            id: "smart.fillers",
            title: "Remove filler words",
            subtitle: "Delete uh / um / you know / like / so etc.",
            systemImage: "scissors",
            group: .smartCut,
            action: .seedPrompt(
                L("Find every filler word in the transcript "
                + "(uh, um, you know, like, so, etc.) and remove them.")
            ),
            shortcutLabel: "⌘⇧2"
        ),

        // MARK: Speaker
        .init(
            id: "speaker.detect",
            title: "Detect speakers",
            subtitle: "Split the transcript by who's talking",
            systemImage: "person.2.wave.2",
            group: .speaker,
            action: .seedPrompt(L("Identify every distinct voice in the video and label who says what."))
        ),
        .init(
            id: "speaker.mute",
            title: "Mute a speaker",
            subtitle: "Silence every cue from one person",
            systemImage: "speaker.slash",
            group: .speaker,
            action: .seedPrompt(
                L("Identify each speaker in the video, then mute every line "
                + "spoken by <fill in which speaker>.")
            ),
            requiresInputBeforeSubmit: true
        ),
        .init(
            id: "speaker.list",
            title: "List what a speaker said",
            subtitle: "Show every line one person said",
            systemImage: "text.bubble",
            group: .speaker,
            action: .seedPrompt(
                L("Identify each speaker in the video, then list every line "
                + "spoken by <fill in which speaker>.")
            ),
            requiresInputBeforeSubmit: true
        ),

        // MARK: Vision
        .init(
            id: "vision.empty",
            title: "Find empty frames",
            subtitle: "Spans with no face on screen",
            systemImage: "person.slash",
            group: .vision,
            action: .seedPrompt(L("List every span in the video where no face is visible on screen."))
        ),
        .init(
            id: "vision.black",
            title: "Find black frames",
            subtitle: "Near-black or covered-lens regions",
            systemImage: "square.fill",
            group: .vision,
            action: .seedPrompt(L("Find every span that is near-black or looks like the lens was covered."))
        ),
        .init(
            id: "vision.autoPiP",
            title: "Auto Picture-in-Picture",
            subtitle: "Detect presenter-cam overlays and place them in a tidy corner",
            systemImage: "person.crop.circle.badge.checkmark",
            group: .vision,
            action: .runAutoPiP
        ),

        // MARK: Generative
        .init(
            id: "gen.broll",
            title: "Suggest B-roll spots",
            subtitle: "AI marks places where a visual or overlay would help",
            systemImage: "sparkles.rectangle.stack",
            group: .generative,
            action: .seedPrompt(
                L("Review the current cut and mark the moments where a B-roll "
                + "clip or visual overlay would strengthen the story.")
            )
        ),
        .init(
            id: "gen.title",
            title: "Suggest 3 titles",
            subtitle: "Candidate titles from the transcript",
            systemImage: "text.cursor",
            group: .generative,
            action: .seedPrompt(L("Suggest 3 English title candidates based on the transcript."))
        ),
        .init(
            id: "gen.chapters",
            title: "Generate chapter bar",
            subtitle: "AI splits the cut into titled chapters and burns a YouTube-style progress bar",
            systemImage: "list.bullet.rectangle",
            group: .generative,
            action: .runChapterGeneration
        ),
        .init(
            id: "gen.hook",
            title: "Pick an opening hook",
            subtitle: "AI scores hook candidates from the recordings; you pick which one to splice in",
            systemImage: "quote.opening",
            group: .generative,
            action: .seedPrompt(
                L("Pick the best opening hook (cold-open teaser) from the "
                + "recordings. Call score_hook_candidates with top_k=5, "
                + "present the candidates with their punch reasoning so I "
                + "can pick one, and after I confirm a choice call "
                + "add_hook_teaser with that candidate's source_video_id, "
                + "source_start, and source_end. Do not pick or apply "
                + "automatically — always wait for my reply.")
            ),
            shortcutLabel: "⌘⇧3"
        ),
        .init(
            id: "gen.overlayTitles",
            title: "Suggest animated title cards",
            subtitle: "AI picks moments for Remotion ChapterTitle overlays and generates them on approval",
            systemImage: "sparkles.tv",
            group: .generative,
            action: .seedPrompt(
                L("Review the current cut and pick 3–5 moments best suited for a "
                + "ChapterTitle animated title card (chapter starts, topic shifts, "
                + "emphasis sections, etc.). First list each suggestion with: "
                + "composed_time (seconds), title, optional subtitle, "
                + "theme (dark/light/accent), and a brief reason. After the user "
                + "confirms, call the generate_overlay tool for each accepted "
                + "suggestion (template_id=\"ChapterTitle\", props_json filled per "
                + "the fields above, durationSeconds defaults to 2.5). After "
                + "generation, remind the user they can double-click the overlay "
                + "in the Inspector to fine-tune copy or theme.")
            )
        ),
        .init(
            id: "gen.image",
            title: "Generate AI image",
            subtitle: "Describe an image and drop it into the Media Browser",
            systemImage: "photo.badge.plus",
            group: .generative,
            action: .openImageGen
        ),
        .init(
            id: "gen.summary",
            title: "Summarize the video",
            subtitle: "Short paragraph describing what it's about",
            systemImage: "doc.text.magnifyingglass",
            group: .generative,
            action: .seedPrompt(L("Write a 3-4 sentence English summary of the current video."))
        ),

        // MARK: Subtitles
        .init(
            id: "subtitle.bilingual.zh-en",
            title: "Add bilingual subtitles (中 ↔ EN)",
            subtitle: "Auto-translate between Chinese and English, show both lines",
            systemImage: "character.bubble",
            group: .subtitles,
            action: .seedPrompt(SubtitlePrompts.bilingualZhEn)
        ),
        .init(
            id: "subtitle.translate.en",
            title: "Add English translation line",
            subtitle: "Translate subtitles to English and render below",
            systemImage: "text.badge.plus",
            group: .subtitles,
            action: .seedPrompt(SubtitlePrompts.translateToEnglish)
        ),
        .init(
            id: "subtitle.translate.zh",
            title: "Add Chinese translation line",
            subtitle: "Translate subtitles to Chinese and render below",
            systemImage: "text.badge.plus",
            group: .subtitles,
            action: .seedPrompt(SubtitlePrompts.translateToChinese)
        ),
        .init(
            id: "subtitle.translate.custom",
            title: "Translate subtitles to…",
            subtitle: "Fill in the target language, then send",
            systemImage: "globe",
            group: .subtitles,
            action: .seedPrompt(SubtitlePrompts.translateToCustom),
            requiresInputBeforeSubmit: true
        ),
        ]
    }

    static func byGroup() -> [(Group, [AgentWorkflowPreset])] {
        Group.allCases.map { g in
            (g, all.filter { $0.group == g })
        }
    }

    /// Preset ids that depend on the cloud animation pipeline. Hidden
    /// from BYOK users since the underlying tools (`generate_overlay`,
    /// the proprietary Remotion skill) are unavailable when on a
    /// custom AI provider. Image-generation presets stay visible —
    /// BYOK does support image generation through the user's own API.
    static let cloudOnlyPresetIDs: Set<String> = [
        "gen.overlayTitles"
    ]

    /// Returns the catalog filtered for the given AI provider. BYOK
    /// (`.custom`) callers should use this instead of `.all` so that
    /// animation-only presets don't appear in the workflow menu.
    static func available(for provider: AIProviderPreference) -> [AgentWorkflowPreset] {
        guard provider == .custom else { return all }
        return all.filter { !cloudOnlyPresetIDs.contains($0.id) }
    }

    static func byGroup(for provider: AIProviderPreference) -> [(Group, [AgentWorkflowPreset])] {
        let visible = available(for: provider)
        return Group.allCases.map { g in
            (g, visible.filter { $0.group == g })
        }
    }
}

extension AgentWorkflowPreset {
    /// How a `.seedPrompt` preset should be triggered. `nil` for
    /// non-prompt actions (those have dedicated `onRun*` callbacks).
    enum SeedPromptTrigger: Equatable {
        /// Fill the chat composer with the prompt and let the user
        /// edit before they hit Enter. Used for placeholder presets
        /// (`requiresInputBeforeSubmit == true`) and for the explicit
        /// "Edit before sending" escape hatch (Option-click / context
        /// menu).
        case fillComposer(prompt: String)
        /// Send the prompt straight to the agent loop. The chat
        /// history bubble shows `displayLabel` (the preset's
        /// localized title) instead of the verbose internal prompt;
        /// the LLM still receives the full prompt as the user
        /// message's `content`.
        case autoSend(prompt: String, displayLabel: String)
    }

    /// Decide how this preset should fire when the user invokes it.
    ///
    /// Policy (single source of truth so plain-click / shortcut /
    /// context-menu paths can't drift):
    ///   • Non-`.seedPrompt` actions → returns `nil`. Pipeline presets
    ///     and the image-generation sheet are dispatched through their
    ///     own callbacks, not the prompt path.
    ///   • `requiresInputBeforeSubmit == true` → always
    ///     `.fillComposer`. These prompts contain `<fill in ...>` /
    ///     `<填入...>` placeholders and would be useless to auto-send.
    ///   • `forceFillComposer == true` (Option-click / "Edit before
    ///     sending") → `.fillComposer`. Lets the user peek or tweak a
    ///     normally auto-sending prompt.
    ///   • Otherwise → `.autoSend` with the localized preset title as
    ///     the chat display label. The chat history shows a clean
    ///     action chip instead of the raw scaffolded prompt.
    func seedPromptTrigger(forceFillComposer: Bool = false) -> SeedPromptTrigger? {
        guard case .seedPrompt(let text) = action else { return nil }
        if forceFillComposer || requiresInputBeforeSubmit {
            return .fillComposer(prompt: text)
        }
        return .autoSend(prompt: text, displayLabel: L(title))
    }
}

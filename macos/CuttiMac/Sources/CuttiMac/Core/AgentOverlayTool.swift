import Foundation
import CuttiKit

/// Agent-facing `generate_overlay` tool — lets the LLM ask the Swift
/// client to render one of the checked-in Remotion templates and drop
/// the resulting transparent ProRes 4444 `.mov` onto the overlay track
/// at a specific composed-time anchor.
///
/// The tool is deliberately narrow: it does NOT expose the full Remotion
/// API surface. Instead the LLM picks a `template_id` out of a small
/// curated catalog (see `RemotionOverlayCatalog.systemPromptDescription`)
/// and supplies a `props_json` string that must validate against that
/// template's zod schema on the Remotion side. Parsing on the Swift
/// side is intentionally permissive — we only sanity-check the shape
/// of the arguments; schema conformance is enforced by Remotion itself
/// when it renders.
struct GenerateOverlayRequest: Equatable, Sendable {
    /// Composition ID registered in `remotion/src/Root.tsx`. Case
    /// sensitive — the Remotion CLI will fail fast on a typo.
    var templateID: String

    /// Already-encoded JSON props string. Stored verbatim so the call
    /// site can forward it to `RemotionRenderRequest` without another
    /// encode round trip.
    var propsJSON: String

    /// How long the rendered overlay should be. Clamped to a sensible
    /// range here so the agent can't accidentally request a 10-minute
    /// chapter card; individual templates additionally clamp via their
    /// `calculateMetadata` hook.
    var durationSeconds: Double

    /// Start time on the composed timeline (seconds from 0) where the
    /// overlay should begin. Clamped ≥ 0.
    var composedTime: Double

    static func parse(from args: [String: Any]) -> GenerateOverlayRequest? {
        guard let tmpl = (args["template_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !tmpl.isEmpty
        else { return nil }

        // Accept `props_json` either as a raw JSON string (the common
        // case) or as a nested object that the LLM returned inline —
        // OpenAI's function-calling surface sometimes does that despite
        // the schema saying "string". Re-encoding the object keeps the
        // downstream renderer contract unchanged.
        let propsString: String
        if let s = args["props_json"] as? String {
            propsString = s
        } else if let obj = args["props_json"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let encoded = String(data: data, encoding: .utf8) {
            propsString = encoded
        } else {
            return nil
        }

        let rawDuration = (args["duration_seconds"] as? Double)
            ?? (args["duration_seconds"] as? Int).map(Double.init)
            ?? 2.5
        let rawComposed = (args["composed_time"] as? Double)
            ?? (args["composed_time"] as? Int).map(Double.init)
            ?? 0

        return GenerateOverlayRequest(
            templateID: tmpl,
            propsJSON: propsString,
            durationSeconds: max(0.5, min(rawDuration, 30)),
            composedTime: max(0, rawComposed)
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "generate_overlay",
            description: """
            Render a Remotion animated overlay (e.g. chapter-title card) \
            and drop it onto the overlay track at composed_time. Use when \
            the user asks for a title card, chapter break, or other \
            motion-graphic overlay — NOT for inserting already-imported \
            B-roll footage (that's `insert_broll`). \
            Available templates and their props schemas: \
            \(RemotionOverlayCatalog.systemPromptDescription)
            \(AnimationSkill.bakedIntoOverlayPrompt)
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "template_id": .init(
                        type: "string",
                        description: "Composition id registered in Remotion. Currently supported: \(RemotionOverlayCatalog.supportedTemplateIDs.joined(separator: ", ")).",
                        items: nil
                    ),
                    "props_json": .init(
                        type: "string",
                        description: "JSON-encoded props object validated by the template's zod schema on the Remotion side. Must match the template's expected shape.",
                        items: nil
                    ),
                    "duration_seconds": .init(
                        type: "number",
                        description: "Overlay length in seconds (0.5–30). The template clamps further via its own calculateMetadata hook.",
                        items: nil
                    ),
                    "composed_time": .init(
                        type: "number",
                        description: "Start position on the composed timeline in seconds (0-based).",
                        items: nil
                    ),
                ],
                required: ["template_id", "props_json", "composed_time"],
                items: nil
            )
        )
    )
}

/// Small, hand-maintained catalog of Remotion overlay templates the
/// agent is allowed to reference. Kept in Swift (not auto-derived from
/// `remotion/src/Root.tsx`) on purpose — we want a curated doc string
/// that reads well inside a system prompt and only exposes the props
/// the agent should actually touch.
enum RemotionOverlayCatalog {
    static let supportedTemplateIDs: [String] = [
        "ChapterTitle",
        "TitleCard",
        "ChatBubble",
        "PromptTyping",
        "SkillMeter",
        "CodeGen",
        "ContextBar",
        "GitHubCard",
        "TripleTap",
        "SequenceSteps",
        "Quote",
        "Comparison",
    ]

    /// Human-readable description embedded in the `generate_overlay`
    /// tool description and in the main agent system prompt. Keep it
    /// short — every token counts against the budget.
    static let systemPromptDescription: String = """
    [ChapterTitle] Full-bleed translucent chapter card. props: \
    { title: string (1–80), subtitle?: string, durationSeconds?: 1.5–4 default 2.5, \
    theme?: "dark"|"light"|"accent" default "dark", accentColor?: hex default "#00E0C7" (only used when theme=="accent"), \
    titleFontSlug?: fancy-font slug (see FONTS section below) }. \
    Use 2.0s tight, 3.0s with subtitle.

    [TitleCard] Bold product/chapter title card on a solid background, with subtitle and an expanding underline. props: \
    { title: string (1–60), subtitle?: string (≤120), durationSeconds?: 1.5–5 default 3, \
    backgroundColor?: hex default "#0D0D0D", accentColor?: hex default "#FFFFFF", \
    titleFontSlug?: fancy-font slug (see FONTS section below) }. \
    Recommended 3s.

    [ChatBubble] Mocked AI chat window: user bubble pops in, then assistant streams a typed reply. props: \
    { appName: string (1–40), appInitial: string (1–2), userMessage: string (1–400), \
    assistantReply: string (1–600), durationSeconds?: 3–10 default 6, accentColor?: hex default "#10A37F" }. \
    Allow ~0.13s per assistant character.

    [PromptTyping] Large tilted "agent chat" window: long prompt is pasted, sent, and answered. props: \
    { agentName: string, agentStatus?: string, agentAvatar: string (emoji 1–4), \
    promptText: string (1–800), greeting?: string, reply?: string, inputPlaceholder?: string, \
    durationSeconds?: 6–15 default 10, accentColor?: hex default "#6366F1" }. \
    Best at 10s; shorter values clip the assistant reply.

    [SkillMeter] Horizontal gauge with 3 zones (low/sweet-spot/overflow); fills to peak then bounces back to rest. props: \
    { label: string, maxValue: number, lowZoneEnd: number, sweetSpotEnd: number, peakValue: number, restValue: number, \
    lowZoneLabel?: string, sweetSpotLabel?: string, warningText?: string, \
    durationSeconds?: 3–7 default 5, accentColor?: hex default "#34D399" }. \
    Use when arguing "more isn't better".

    [CodeGen] Mocked AI chat (transparent bg) where assistant streams a multi-line reply that may contain a fenced code block. props: \
    { assistantName: string, modelLabel?: string, assistantInitial: string (1–2), \
    userPrompt: string (1–400), replyLines: string[] (1–20, ``` to fence code, ✓ in line tints green), \
    durationSeconds?: 3–8 default 5, accentColor?: hex default "#D97757" }.

    [ContextBar] Animated progress bar fills 0→100%, flashes, then snaps back to a small rest value with a callout. props: \
    { label: string, leftCapLabel?: string, rightCapLabel?: string, calloutText?: string, \
    restPercent?: 0–80 default 15, durationSeconds?: 3–6 default 4, accentColor?: hex default "#FFD700" }. \
    Visualizes context-window compaction / cleanup.

    [GitHubCard] GitHub-style repo card slides up; star count animates 0→target; star button pulses. props: \
    { repoName: string (e.g. "owner/repo"), description: string (≤200), language?: string, \
    languageColor?: hex, targetStars: number, durationSeconds?: 2.5–6 default 4, accentColor?: hex default "#58A6FF" }.

    [TripleTap] Row of 2–6 emoji icons popping in with bounce, then a tagline fades in below. props: \
    { icons: { emoji: string, label: string, accentColor: hex }[] (2–6), tagline: string (1–40), \
    durationSeconds?: 2.5–6 default 4, accentColor?: hex default "#FF4D6A" }. \
    Each extra icon adds ~0.7s of useful runtime; size durationSeconds accordingly.

    [SequenceSteps] Unified "sequence of labelled things" skill with three visual layouts. props: \
    { heading?: string (≤60), \
    layout: "list"|"flow"|"timeline" default "list", \
    orientation: "horizontal"|"vertical" default "horizontal" (only used by layout="flow"; timeline is always horizontal, list always vertical), \
    listStyle: "numbered"|"bulleted"|"emoji" default "numbered" (only used by layout="list"), \
    items: { label: string (≤80), icon?: emoji (1–4, used by flow & list-emoji), caption?: string (≤20, used by timeline for the date), atSeconds?: 0–60 (when this item should pop in, relative to overlay start) }[] (2–6), \
    durationSeconds?: 3–30 default 6, accentColor?: hex default "#00E0C7" }. \
    Pick layout by the spoken content: \
      - layout="list" for enumerations ("first… second… third…", "三点建议") \
      - layout="flow" for process descriptions ("A → B → C", "先 X 再 Y 最后 Z") \
      - layout="timeline" for dated chronology ("2020 创立，2022 融资，2024 上线"). \
    CRITICAL timing: when given an anchor window (the speaker's span), set durationSeconds = anchor window length and fill each item's atSeconds from the transcript cue where that item is actually uttered — the overlay's rhythm should mirror the voiceover. If atSeconds is omitted on every item the template falls back to even spacing, but an even schedule rarely matches real speech cadence. Keep 2–6 items; long label text wraps ugly.

    [Quote] Pull-quote card for a memorable sentence. Giant opening quote mark, italic serif body, attribution with a short rule. props: \
    { quote: string (1–240), attribution?: string (≤80), \
    durationSeconds?: 2.5–6 default 4, \
    backgroundColor?: hex default "#0D0D0D", accentColor?: hex default "#00E0C7", \
    quoteFontSlug?: fancy-font slug (see FONTS section below) }. \
    Use for punchline/thesis sentences, aphorisms, quoted lines worth holding on screen.

    [Comparison] Two-column "A vs B" / "before vs after" card with its own accent per side and a VS divider. props: \
    { heading?: string (≤60), \
    left: { title: string (≤30), bullets: string[] (1–5, each ≤60), accentColor: hex }, \
    right: { title: string (≤30), bullets: string[] (1–5, each ≤60), accentColor: hex }, \
    dividerLabel: string (≤12) default "VS", \
    durationSeconds?: 4–8 default 6 }. \
    Use when the speaker contrasts two options/eras/approaches. Keep bullets parallel in number and length for legibility.

    FONTS: templates that expose `titleFontSlug` / `quoteFontSlug` accept one of these slugs (omit the prop to keep default system stack). Pick by vibe, not by name; don't use script fonts for long paragraphs (≥ 6-7 words reads poorly). \
    Latin display: \
      lobster (retro diner script), pacifico (surf brush), dancing-script (elegant cursive), caveat (handwritten marker), great-vibes (ornate copperplate), permanent-marker (thick sharpie, rebellious), bebas-neue (tall narrow caps, documentary), playfair-display (editorial serif). \
    CJK display (simplified Chinese glyph coverage): \
      ma-shan-zheng (毛笔楷书，抒情), zcool-kuaile (圆胖卡通，Vlog 可爱), zcool-xiaowei (瘦宋，文艺), zcool-qingke-huangyou (超粗黑，砸屏), long-cang (行书，飘逸), zhi-mang-xing (手写行书，随笔), liu-jian-mao-cao (草书，1-2 字金句专用), noto-serif-sc (思源宋，正文). \
    Rule: if the caption is Chinese, prefer a CJK slug; mixed-language titles still work because the full fallback stack comes after the slug font. Unset = safest default (system sans/serif).

    BACKDROP: almost every template accepts `backdropMode: "transparent" | "dim" | "solid"` — it controls how much of the primary video the overlay covers. \
      - "transparent" (default for content cards: TitleCard, Quote, Comparison, ContextBar, GitHubCard, SequenceSteps, SkillMeter, TripleTap): outer fill is fully transparent, so only the inner text / cards / icons sit over the original footage. Best for short callouts on clean footage, lower-thirds, "floating" annotations. \
      - "dim": outer fill is a 45%-black wash. Darkens the footage so bright overlay content pops without fully hiding the speaker. Safe fallback when the footage is busy / bright and transparent would be unreadable. \
      - "solid" (default for ChapterTitle & PromptTyping, also available for every template): outer fill paints the template's opaque backgroundColor full-bleed. Fully hides the video behind — use for chapter takeovers, dedicated "cut to a UI mock" moments, or any time you want the original video to disappear for the duration of the overlay. \
    ChatBubble and CodeGen don't take backdropMode — they always float (their chat window chrome *is* the content). \
    Default bias: start with "transparent" for content-cards. Only escalate to "dim" / "solid" if the overlay is long, text-heavy, or the speaker is explicitly doing a section break.
    """
}

/// Agent-facing `update_overlay_props` tool — lets the LLM (or the
/// Inspector panel in the UI) edit the props of a previously-generated
/// overlay. The segment's id is the stable handle, the `props_patch` is
/// merged onto the existing `overlaySpec.propsJSON`, and the Mac side
/// re-renders through the content-addressable cache, swapping the
/// segment's mediaID to the new asset.
///
/// This is the tool that makes AI-generated overlays re-editable: the
/// user can say "change the chapter title to '第二章' and make it
/// lighter" and the agent emits an `update_overlay_props` call with
/// `{ "title": "第二章", "theme": "light" }` — no need to delete and
/// regenerate.
struct UpdateOverlayPropsRequest: Equatable, Sendable {
    /// UUID of the `TimelineSegment` whose overlaySpec should be edited.
    /// Must be an overlay-track segment that was originally created via
    /// `generate_overlay` (i.e. has a non-nil `overlaySpec`).
    var segmentID: UUID

    /// Canonical JSON string encoding the patch object. Merged on top
    /// of the segment's existing props; nested objects are NOT deep-
    /// merged (last-write-wins on top-level keys). Stored as a string
    /// for round-trip safety.
    var propsPatchJSON: String

    static func parse(from args: [String: Any]) -> UpdateOverlayPropsRequest? {
        guard let idString = (args["segment_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: idString)
        else { return nil }

        let patchString: String
        if let s = args["props_patch"] as? String {
            patchString = s
        } else if let obj = args["props_patch"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let encoded = String(data: data, encoding: .utf8) {
            patchString = encoded
        } else {
            return nil
        }

        // Sanity-check: patch must be a JSON object. Scalars / arrays
        // don't make sense here and would only confuse the merge path.
        guard let patchData = patchString.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: patchData)) as? [String: Any] != nil
        else { return nil }

        return UpdateOverlayPropsRequest(segmentID: uuid, propsPatchJSON: patchString)
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "update_overlay_props",
            description: """
            Edit the props of an existing AI-generated overlay (one that \
            was previously created via `generate_overlay`). The `props_patch` \
            is merged onto the overlay's current props; the Mac app re-renders \
            the Remotion template with the new props and swaps the segment's \
            media to the new render. The overlay keeps its id, placement, and \
            duration — only the props change. Use this when the user asks to \
            tweak the text / color / theme of a title card they already see on \
            the timeline, rather than deleting and re-generating.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "segment_id": .init(
                        type: "string",
                        description: "UUID of the overlay TimelineSegment to edit. Must refer to an AI-generated overlay (one with an overlaySpec).",
                        items: nil
                    ),
                    "props_patch": .init(
                        type: "string",
                        description: "JSON object of props to merge onto the overlay's existing props. Last-write-wins on overlapping keys. Props not mentioned in the patch are preserved unchanged.",
                        items: nil
                    ),
                ],
                required: ["segment_id", "props_patch"],
                items: nil
            )
        )
    )
}

import Foundation
import CuttiKit

// MARK: - run_first_cut
//
// Exposes the "One-click first cut" pipeline (transcribe → scene/audio
// analysis → 4-pass LLM cleanup) as an agent tool, so the chat agent can
// invoke the same flow that lives behind the ⌘⇧1 shortcut and the
// AgentWorkflowPresets entry. The tool is mutating: a pre-state revision
// is pushed before running so `restore_checkpoint` can rewind past it,
// and the resulting `userSummary` shows up in the chat trail with a
// `checkpointID` like every other revertable agent step.
//
// Parameters are intentionally minimal — the pipeline derives clip
// targets from the project itself (every "ready" clip without an
// existing copilot snapshot). An optional `clip_id` lets the agent
// re-analyze a specific clip when the user asks for that explicitly.

struct RunFirstCutRequest: Equatable, Sendable {
    /// When set, run the analysis on this single imported clip's UUID.
    /// When nil, run on every ready clip that does not yet have a
    /// copilot snapshot (matches the manual ⌘⇧1 entry point).
    var clipID: UUID?

    static func parse(from args: [String: Any]) -> RunFirstCutRequest {
        let raw = (args["clip_id"] as? String).flatMap { UUID(uuidString: $0) }
        return RunFirstCutRequest(clipID: raw)
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "run_first_cut",
            description: """
            Run the full AI first-cut pipeline (transcribe → analyze → 4-pass LLM cleanup) on imported clips. Auto-trims silences, duplicate takes, and half-finished sentences to produce a clean first edit. Equivalent to the manual ⌘⇧1 "One-click first cut" command.

            When to call:
            • The user asks for a vague auto-edit ("帮我剪一下", "make a first cut", "auto-edit this", "clean it up").
            • The current timeline is empty (or only contains raw imports) and the user requests any edit.
            • The user explicitly asks to redo the first cut after importing more clips.

            Slow — transcription dominates and may take minutes for long clips. Mutating: a checkpoint is pushed so the user can revert via restore_checkpoint. Skips clips that already have an analysis snapshot unless `clip_id` is given.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "clip_id": .init(
                        type: "string",
                        description: "UUID of a specific imported clip to analyze. Omit to run on every ready clip that hasn't been analyzed yet (the usual case).",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

struct RunFirstCutToolResult: Encodable, Sendable {
    let ok: Bool
    let segments: Int
    let totalDurationSeconds: Double
    /// Number of clips actually transcribed/analyzed in this call.
    /// Zero means everything was already cached and we just rebuilt.
    let analyzedClips: Int
    /// Total clips visible to the pipeline (ready or already analyzed).
    let totalClips: Int
    let note: String?
}

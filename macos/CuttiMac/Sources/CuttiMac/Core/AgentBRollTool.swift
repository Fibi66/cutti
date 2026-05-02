import Foundation

/// Agent-facing bridge for the "propose B-roll visuals" pass. Exposed
/// as a tool so the LLM can explicitly request fresh suggestions after
/// a non-trivial edit (e.g. the user just restructured segments and
/// wants the visual-director output re-run against the new cut).
struct SuggestBRollRequest: Equatable, Sendable {
    /// Optional source hint — when present, limits suggestions to that
    /// specific clip. Otherwise every unique source referenced by the
    /// current timeline is refreshed.
    var sourceVideoID: UUID?

    static func parse(from args: [String: Any]) -> SuggestBRollRequest {
        let idStr = args["source_video_id"] as? String
        return SuggestBRollRequest(sourceVideoID: idStr.flatMap(UUID.init(uuidString:)))
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "suggest_broll",
            description: "Ask the visual-director model where charts, animations, images, or other B-roll would strengthen the current cut. Results appear as bubbles above the primary track; users can dismiss or later generate images from them. Run after significant timeline changes.",
            parameters: .init(
                type: "object",
                properties: [
                    "source_video_id": .init(
                        type: "string",
                        description: "Optional UUID; if provided, only refresh suggestions for that source clip.",
                        items: nil
                    )
                ],
                required: nil,
                items: nil
            )
        )
    )
}

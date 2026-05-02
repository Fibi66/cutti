import Foundation

/// "Creative" Agent actions — additive operations that go beyond
/// trim/delete/speed (which AIAction already covers). Kept in a separate
/// enum for now so we can iterate on rendering support independently of
/// the frozen `AIAction` executor surface.
public enum CreativeAction: Codable, Equatable, Sendable {
    case insertTitleCard(composedTime: Double, text: String, duration: Double, style: String)
    case insertBRoll(composedTime: Double, mediaID: UUID, duration: Double, muteOriginal: Bool)
    case applyKenBurns(segmentID: UUID, startRect: UnitRect, endRect: UnitRect)
    case insertCrossfade(fromSegmentID: UUID, toSegmentID: UUID, duration: Double)

    public struct UnitRect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var summary: String {
        switch self {
        case .insertTitleCard(let t, let text, let dur, _):
            return "Insert title \"\(text)\" at \(String(format: "%.1fs", t)) for \(String(format: "%.1fs", dur))"
        case .insertBRoll(let t, _, let dur, _):
            return "Insert B-roll at \(String(format: "%.1fs", t)) for \(String(format: "%.1fs", dur))"
        case .applyKenBurns:
            return "Apply Ken Burns zoom"
        case .insertCrossfade(_, _, let dur):
            return "Crossfade \(String(format: "%.1fs", dur))"
        }
    }

    /// OpenAI function-calling schema for registration in the Agent tool
    /// palette. Shipped as JSON so the LLM bridge can copy it verbatim.
    public static let functionSchemas: [String: String] = [
        "insert_title_card": #"""
        {
          "name": "insert_title_card",
          "description": "Insert a solid-color title card with centered text at a given composed time.",
          "parameters": {
            "type": "object",
            "properties": {
              "composed_time": {"type": "number"},
              "text": {"type": "string"},
              "duration": {"type": "number"},
              "style": {"type": "string"}
            },
            "required": ["composed_time", "text", "duration"]
          }
        }
        """#,
        "insert_broll": #"""
        {
          "name": "insert_broll",
          "description": "Overlay a secondary media asset on top of the main track.",
          "parameters": {
            "type": "object",
            "properties": {
              "composed_time": {"type": "number"},
              "media_id": {"type": "string"},
              "duration": {"type": "number"},
              "mute_original": {"type": "boolean"}
            },
            "required": ["composed_time", "media_id", "duration"]
          }
        }
        """#,
        "apply_ken_burns": #"""
        {
          "name": "apply_ken_burns",
          "description": "Animate a pan + zoom across a segment between two unit-space rects.",
          "parameters": {
            "type": "object",
            "properties": {
              "segment_id": {"type": "string"},
              "start_rect": {"type": "object"},
              "end_rect": {"type": "object"}
            },
            "required": ["segment_id", "start_rect", "end_rect"]
          }
        }
        """#,
        "insert_crossfade": #"""
        {
          "name": "insert_crossfade",
          "description": "Crossfade two adjacent segments over the given duration.",
          "parameters": {
            "type": "object",
            "properties": {
              "from_segment_id": {"type": "string"},
              "to_segment_id": {"type": "string"},
              "duration": {"type": "number"}
            },
            "required": ["from_segment_id", "to_segment_id", "duration"]
          }
        }
        """#,
    ]

    /// Parse an `insert_crossfade` tool argument bag into a
    /// CreativeAction. Returns nil on missing / malformed fields.
    public static func parseInsertCrossfade(from args: [String: Any]) -> CreativeAction? {
        guard let fromString = args["from_segment_id"] as? String,
              let from = UUID(uuidString: fromString) else { return nil }
        guard let toString = args["to_segment_id"] as? String,
              let to = UUID(uuidString: toString) else { return nil }
        guard let duration = (args["duration"] as? Double) ?? (args["duration"] as? Int).map(Double.init) else { return nil }
        return .insertCrossfade(fromSegmentID: from, toSegmentID: to, duration: max(0.05, duration))
    }
}

/// Parsed form of an `insert_broll` tool call. Validates / coerces the
/// incoming JSON-ish argument bag produced by the LLM so the agent
/// dispatcher can hand a well-formed action to `CreativeActionExecutor`.
public struct InsertBRollRequest: Equatable {
    public var composedTime: Double
    public var mediaID: UUID
    public var duration: Double
    public var muteOriginal: Bool

    public init(composedTime: Double, mediaID: UUID, duration: Double, muteOriginal: Bool) {
        self.composedTime = composedTime
        self.mediaID = mediaID
        self.duration = duration
        self.muteOriginal = muteOriginal
    }

    public static func parse(from args: [String: Any]) -> InsertBRollRequest? {
        guard let composed = (args["composed_time"] as? Double) ?? (args["composed_time"] as? Int).map(Double.init) else { return nil }
        guard let mediaString = args["media_id"] as? String, let mediaID = UUID(uuidString: mediaString) else { return nil }
        guard let duration = (args["duration"] as? Double) ?? (args["duration"] as? Int).map(Double.init) else { return nil }
        let mute = (args["mute_original"] as? Bool) ?? true
        return InsertBRollRequest(
            composedTime: max(0, composed),
            mediaID: mediaID,
            duration: max(0.1, duration),
            muteOriginal: mute
        )
    }

    public var asCreativeAction: CreativeAction {
        .insertBRoll(
            composedTime: composedTime,
            mediaID: mediaID,
            duration: duration,
            muteOriginal: muteOriginal
        )
    }
}

/// Translates the currently-supported creative actions into concrete
/// changes on a segment list. For now only `insertCrossfade` is
/// end-to-end; other cases return `nil` so callers can gracefully defer.
public enum CreativeActionMapper {

    public struct CrossfadePlan: Equatable {
        public var fromSegmentIndex: Int
        public var toSegmentIndex: Int
        public var duration: Double

        public init(fromSegmentIndex: Int, toSegmentIndex: Int, duration: Double) {
            self.fromSegmentIndex = fromSegmentIndex
            self.toSegmentIndex = toSegmentIndex
            self.duration = duration
        }
    }

    public static func plan(
        crossfade action: CreativeAction,
        in segments: [TimelineSegment]
    ) -> CrossfadePlan? {
        guard case .insertCrossfade(let fromID, let toID, let duration) = action else { return nil }
        guard
            let fromIdx = segments.firstIndex(where: { $0.id == fromID }),
            let toIdx = segments.firstIndex(where: { $0.id == toID }),
            toIdx == fromIdx + 1
        else { return nil }
        let clamped = max(0.05, min(duration, min(segments[fromIdx].durationSeconds,
                                                   segments[toIdx].durationSeconds) / 2))
        return CrossfadePlan(fromSegmentIndex: fromIdx, toSegmentIndex: toIdx, duration: clamped)
    }

    public static func apply(
        crossfade plan: CrossfadePlan,
        to segments: [TimelineSegment]
    ) -> [TimelineSegment] {
        guard plan.fromSegmentIndex >= 0,
              plan.toSegmentIndex < segments.count,
              plan.toSegmentIndex == plan.fromSegmentIndex + 1
        else { return segments }
        var out = segments
        out[plan.fromSegmentIndex].effects.audioFadeOutDuration = max(
            out[plan.fromSegmentIndex].effects.audioFadeOutDuration,
            plan.duration
        )
        out[plan.toSegmentIndex].effects.audioFadeInDuration = max(
            out[plan.toSegmentIndex].effects.audioFadeInDuration,
            plan.duration
        )
        return out
    }
}

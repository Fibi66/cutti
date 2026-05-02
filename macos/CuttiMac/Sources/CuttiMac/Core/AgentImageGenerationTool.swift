import Foundation

/// Agent-facing `generate_image` tool — lets the LLM ask the Swift
/// client to generate a FLUX image from a natural-language prompt and
/// either drop it into the Media Browser (freeform) or insert it as
/// a B-roll image overlay at `composed_time`.
///
/// Unlike `generate_overlay` (which renders Remotion motion-graphic
/// templates with rigid zod schemas), this tool produces a single
/// still PNG. It's the right tool whenever the user describes content
/// they want to SEE — a cat, a skyline, a diagram — rather than an
/// animated title / chapter card.
struct GenerateImageRequest: Equatable, Sendable {
    var prompt: String
    /// One of the three whitelisted GPT Image 2 sizes, matching
    /// `ImageGenerationSize`. Default is landscape.
    var size: ImageGenerationSize
    /// If non-nil, after generation the image is inserted as a 4 s
    /// image B-roll overlay at this composed time. If nil, the image
    /// is only added to the Media Browser.
    var insertAt: Double?
    /// Only used when `insertAt` is non-nil. Clamped 0.5…10.
    var durationSeconds: Double

    static func parse(from args: [String: Any]) -> GenerateImageRequest? {
        guard let promptRaw = (args["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !promptRaw.isEmpty
        else { return nil }

        let sizeStr = (args["size"] as? String)?.lowercased() ?? ""
        let size: ImageGenerationSize
        switch sizeStr {
        case "square", "1024x1024":
            size = .square
        case "portrait", "1024x1536", "1024x1792":
            size = .portrait
        case "", "landscape", "1536x1024", "1792x1024":
            size = .landscape
        default:
            size = .landscape
        }

        let insertAt: Double? = {
            if let d = args["composed_time"] as? Double { return max(0, d) }
            if let i = args["composed_time"] as? Int { return max(0, Double(i)) }
            return nil
        }()

        let rawDuration = (args["duration_seconds"] as? Double)
            ?? (args["duration_seconds"] as? Int).map(Double.init)
            ?? 4.0

        return GenerateImageRequest(
            prompt: promptRaw,
            size: size,
            insertAt: insertAt,
            durationSeconds: max(0.5, min(rawDuration, 10))
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "generate_image",
            description: """
            Generate a single still image from a text prompt using FLUX.2-pro \
            and add it to the user's Media Browser. Use whenever the user \
            describes a STATIC visual they want to see (a photo, illustration, \
            diagram, icon, background plate, etc.). DO NOT use for animated \
            title/chapter cards — that's `generate_overlay` with a Remotion \
            template. Behavior: \
            (a) if `composed_time` is provided, the generated image is also \
            inserted as a 4-second image B-roll overlay at that time; \
            (b) if `composed_time` is omitted, the image only lands in the \
            Media Browser and the user drags it onto the timeline themselves. \
            If the user hasn't described what the image should show, ASK a \
            brief clarifying question in a regular assistant message instead \
            of calling this tool with a vague prompt.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "prompt": .init(
                        type: "string",
                        description: "Detailed English description of the image. Be specific about subject, style, lighting, composition. 5–200 words works best. If the user gave a short phrase, expand it with reasonable defaults before calling.",
                        items: nil
                    ),
                    "size": .init(
                        type: "string",
                        description: "One of: 'landscape' (1792×1024, default — good for video B-roll), 'portrait' (1024×1792), 'square' (1024×1024).",
                        items: nil
                    ),
                    "composed_time": .init(
                        type: "number",
                        description: "Optional. If provided, the image is auto-inserted as a 4 s overlay at this composed-time (seconds, 0-based). Omit to only add to the Media Browser.",
                        items: nil
                    ),
                    "duration_seconds": .init(
                        type: "number",
                        description: "Only used with composed_time. Overlay length in seconds (0.5–10, default 4).",
                        items: nil
                    ),
                ],
                required: ["prompt"],
                items: nil
            )
        )
    )
}

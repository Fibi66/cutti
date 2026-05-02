import AVFoundation
import AppKit
import CoreMedia
import Foundation
import CuttiKit

// MARK: - Agent Vision Frame Tool
//
// Exposes `get_frame_at` to the AI agent: sample a single JPEG
// thumbnail at a given composed-time instant, base64-encode it, and
// return it as a data URL the LLM (gpt-4o family) can inspect as a
// vision input. Also returns the text of any subtitle cue covering
// that instant so the model has both picture + caption in context.

struct GetFrameAtRequest: Equatable, Sendable {
    var composedTime: Double
    /// Longest edge of the returned JPEG in pixels. Small values keep
    /// token cost down. Capped between 256 and 1024.
    var maxDimension: Int

    static func parse(from args: [String: Any]) -> GetFrameAtRequest? {
        guard let raw = (args["composed_time"] as? Double)
            ?? (args["composed_time"] as? Int).map(Double.init) else { return nil }
        let rawMax = (args["max_dimension"] as? Int)
            ?? (args["max_dimension"] as? Double).map(Int.init)
            ?? 512
        return GetFrameAtRequest(
            composedTime: max(0, raw),
            maxDimension: max(256, min(rawMax, 1024))
        )
    }

    static let toolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "get_frame_at",
            description: "Return a still frame of the composed timeline at composed_time (seconds) plus the active subtitle cue text. The JPEG is base64-encoded — use it for visual questions ('is the subject centered', 'what's written on that sign', 'is this shot well-lit'). Max 1024px longest edge; default 512.",
            parameters: .init(
                type: "object",
                properties: [
                    "composed_time": .init(
                        type: "number",
                        description: "Instant in the composed timeline, in seconds, to sample.",
                        items: nil
                    ),
                    "max_dimension": .init(
                        type: "number",
                        description: "Longest-edge pixel size of the returned JPEG. 256 to 1024, default 512.",
                        items: nil
                    )
                ],
                required: ["composed_time"],
                items: nil
            )
        )
    )
}

/// Pure helper: sample a JPEG of the composed timeline at `composedTime`.
/// Given:
///  - `segments` — live primary-track segments,
///  - `sourceURLByID` — mapping from source video UUID to file URL,
/// produces an NSImage at most `maxDimension` pixels wide/tall. Returns
/// nil when the time falls outside the timeline, the source is missing,
/// or the image generator fails.
enum AgentFrameSampler {
    static func sample(
        composedTime: Double,
        segments: [TimelineSegment],
        sourceURLByID: [UUID: URL],
        maxDimension: Int
    ) async -> (jpegData: Data, sourceTime: Double, segmentID: UUID)? {
        let index = ComposedTimelineIndex.build(from: segments)
        guard let entry = index.segmentAt(composedTime: composedTime) else { return nil }
        guard let sourceTuple = index.toSourceTime(composedTime) else { return nil }
        guard let url = sourceURLByID[sourceTuple.sourceVideoID] else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let time = CMTime(seconds: sourceTuple.sourceTime, preferredTimescale: 600)

        let cgImage: CGImage? = await withCheckedContinuation { cont in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                cont.resume(returning: image)
            }
        }
        guard let cgImage else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        return (jpeg, sourceTuple.sourceTime, entry.segmentID)
    }
}

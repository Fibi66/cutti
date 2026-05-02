import AVFoundation
import Foundation
import CuttiKit

protocol AssetAnalyzing: Sendable {
    func analyze(url: URL) async throws -> AnalysisSummary
}

struct AVAssetAnalyzer: AssetAnalyzing {
    func analyze(url: URL) async throws -> AnalysisSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "Cutti.AVAssetAnalyzer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No video track found"
            ])
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)

        return AnalysisSummary(
            durationSeconds: CMTimeGetSeconds(duration),
            width: Int(abs(naturalSize.width)),
            height: Int(abs(naturalSize.height)),
            nominalFPS: Double(nominalFPS),
            hasAudio: !audioTracks.isEmpty
        )
    }
}

import SwiftUI
import AVFoundation
import CuttiKit

/// Tiny in-memory thumbnail cache keyed by (mediaID, sourceSeconds).
/// Extracts a frame via AVAssetImageGenerator on a background task.
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    @Published private(set) var images: [String: UIImage] = [:]
    private var inflight: Set<String> = []

    func key(mediaID: UUID, atSeconds: Double) -> String {
        "\(mediaID.uuidString):\(Int(atSeconds * 10))"
    }

    func thumbnail(for url: URL, mediaID: UUID, atSeconds: Double) -> UIImage? {
        let k = key(mediaID: mediaID, atSeconds: atSeconds)
        if let cached = images[k] { return cached }
        guard !inflight.contains(k) else { return nil }
        inflight.insert(k)

        Task.detached(priority: .utility) {
            let img = Self.generate(url: url, seconds: atSeconds)
            await MainActor.run {
                if let img { self.images[k] = img }
                self.inflight.remove(k)
            }
        }
        return nil
    }

    private nonisolated static func generate(url: URL, seconds: Double) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

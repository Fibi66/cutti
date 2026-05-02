import Foundation
import AVFoundation

/// Protocol for playback core that creates AVPlayers for proxy URLs.
protocol PlaybackProviding {
    /// Creates an AVPlayer backed by the (possibly cached) asset for the given proxy URL.
    /// - Parameter proxyURL: Full file URL to the proxy media file
    /// - Returns: An AVPlayer instance ready for playback
    func makePlayer(proxyURL: URL) -> AVPlayer

    /// Eagerly loads and caches AVURLAssets for the given proxy URLs so that
    /// subsequent `makePlayer` calls can reuse already-warmed assets.
    /// - Parameter proxyURLs: Full file URLs to prewarm
    func prepare(proxyURLs: [URL])
}

/// Lightweight wrapper for AVPlayer creation and proxy-only playback.
/// Caches AVURLAssets so that nearby clips share warmed assets.
/// Read-only: never modifies source media, only plays proxies.
///
/// Declared as a reference type (`final class`) so the shared `assetCache` is never
/// silently copied when the value is passed as an `any PlaybackProviding` existential.
/// A `struct` here would exhibit false value-semantics: the `NSCache` reference would
/// be shared across all copies, but callers would have no way to reason about that.
final class AVPlaybackCore: PlaybackProviding {
    private let assetCache = NSCache<NSURL, AVURLAsset>()

    func makePlayer(proxyURL: URL) -> AVPlayer {
        let asset = cachedAsset(for: proxyURL)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        return player
    }

    func prepare(proxyURLs: [URL]) {
        proxyURLs.forEach { _ = cachedAsset(for: $0) }
    }

    private func cachedAsset(for proxyURL: URL) -> AVURLAsset {
        let key = proxyURL as NSURL
        if let cached = assetCache.object(forKey: key) {
            return cached
        }
        let asset = AVURLAsset(url: proxyURL)
        assetCache.setObject(asset, forKey: key)
        return asset
    }
}


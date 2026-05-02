import SwiftUI
import AVFoundation
import UIKit

/// Lightweight UIViewRepresentable around AVPlayerLayer. Unlike
/// `VideoPlayer` (which wraps AVPlayerViewController and brings its
/// own controls + hit-testing), this exposes just the raw player
/// surface so we can render the same AVPlayer twice — for example a
/// blurred aspect-fill background + an aspect-fit foreground.
/// AVPlayerLayer supports multiple layer references to one AVPlayer
/// and will keep them in sync.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    final class Container: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Container {
        let v = Container()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = videoGravity
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: Container, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

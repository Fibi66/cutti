import SwiftUI
import AVKit
import os
import CuttiKit

private let ppLog = Logger(subsystem: "app.cutti.ios", category: "PreviewPane")

private func ppTrace(_ msg: String) {
    ppLog.log("\(msg, privacy: .public)")
    NSLog("[PreviewPane] %@", msg)
}

/// Preview pane: plays the current project's primary-track segments
/// back-to-back via `IOSCompositionBuilder`. The `AVPlayer` itself is
/// owned by `ProjectDocument` so the timeline view can read playback
/// time and seek via taps. We only manage the current item here.
struct PreviewPane: View {
    @EnvironmentObject private var document: ProjectDocument
    @State private var cachedKey: String = ""
    /// Baseline subtitle position fractions captured at drag start so
    /// the translation deltas accumulate against a fixed origin
    /// instead of the live (already-mutating) style values.
    @State private var dragBaseline: (h: Double, v: Double)?

    var body: some View {
        ZStack {
            Color.black
            if document.manifest.media.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No media in this project yet")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                GeometryReader { geo in
                    let fitted = fit(aspect: document.aspectRatio.ratio, into: geo.size)
                    ZStack {
                        backgroundLayer(size: geo.size)
                        VideoPlayer(player: document.player)
                            .frame(width: fitted.width, height: fitted.height)
                            .clipped()
                        if let lines = document.activeSubtitleLines, !lines.primary.isEmpty {
                            subtitleOverlay(primary: lines.primary, secondary: lines.secondary)
                                .frame(width: fitted.width, height: fitted.height)
                        }
                        TextOverlayDragLayer()
                            .environmentObject(document)
                            .frame(width: fitted.width, height: fitted.height)
                            .allowsHitTesting(true)
                        FreeTransformDragLayer()
                            .environmentObject(document)
                            .frame(width: fitted.width, height: fitted.height)
                        if !document.chapters.isEmpty {
                            VStack {
                                Spacer()
                                ChapterBarStrip()
                                    .environmentObject(document)
                                    .frame(width: fitted.width)
                                    .padding(.bottom, 6)
                            }
                            .frame(width: fitted.width, height: fitted.height)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onAppear { refreshItem() }
        .onChange(of: timelineKey) { _, _ in refreshItem() }
        .onDisappear {
            document.player.pause()
        }
    }

    /// Letterbox / pillarbox fill behind the fitted video. Solid colour
    /// or a blurred aspect-fill of the same AVPlayer (a second
    /// AVPlayerLayer pointed at the same player).
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        switch document.background {
        case .color(let c):
            Color(
                .sRGB,
                red: c.red, green: c.green, blue: c.blue, opacity: c.alpha
            )
            .frame(width: size.width, height: size.height)
        case .blur:
            PlayerLayerView(player: document.player, videoGravity: .resizeAspectFill)
                .frame(width: size.width, height: size.height)
                .blur(radius: 28)
                .clipped()
                .overlay(Color.black.opacity(0.25))
        }
    }

    /// Largest rect of the given aspect that fits inside the container.
    private func fit(aspect: CGFloat, into size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            // content is wider — match width
            return CGSize(width: size.width, height: size.width / aspect)
        } else {
            return CGSize(width: size.height * aspect, height: size.height)
        }
    }

    @ViewBuilder
    private func subtitleOverlay(primary text: String, secondary: String?) -> some View {
        // SubtitleStyle.fontSizePoints is canonical @ 1080p height;
        // scale linearly to the rendered frame size so the overlay
        // matches what's burned-in at export time.
        let style = document.subtitleStyle
        GeometryReader { g in
            let scale = g.size.height / 1080.0
            let fs = max(10, style.fontSizePoints * scale)
            let secondaryFs = max(8, fs * 0.8)
            let vpad = style.backgroundPaddingVertical * scale
            let hpad = style.backgroundPaddingHorizontal * scale
            let bg = Color(
                .sRGB,
                red: style.backgroundColor.red,
                green: style.backgroundColor.green,
                blue: style.backgroundColor.blue,
                opacity: style.backgroundColor.alpha
            )
            let fg = Color(
                .sRGB,
                red: style.textColor.red,
                green: style.textColor.green,
                blue: style.textColor.blue,
                opacity: style.textColor.alpha
            )
            let textAlign: TextAlignment = {
                switch style.alignment {
                case .leading: return .leading
                case .center: return .center
                case .trailing: return .trailing
                }
            }()
            // When the subtitle sits near the bottom (the common case),
            // stack the translation ABOVE the primary line so neither
            // runs off-canvas. Near the top, stack it BELOW.
            let secondaryAbove = style.verticalPositionFraction >= 0.5
            let block = VStack(spacing: 2 * scale) {
                if let sec = secondary, !sec.isEmpty, secondaryAbove {
                    Text(sec)
                        .font(.system(size: secondaryFs, weight: .medium))
                        .multilineTextAlignment(textAlign)
                        .foregroundStyle(fg.opacity(0.9))
                }
                Text(text)
                    .font(.system(size: fs, weight: .semibold))
                    .multilineTextAlignment(textAlign)
                    .foregroundStyle(fg)
                if let sec = secondary, !sec.isEmpty, !secondaryAbove {
                    Text(sec)
                        .font(.system(size: secondaryFs, weight: .medium))
                        .multilineTextAlignment(textAlign)
                        .foregroundStyle(fg.opacity(0.9))
                }
            }
            ZStack(alignment: .topLeading) {
                Color.clear
                block
                    .padding(.horizontal, hpad)
                    .padding(.vertical, vpad)
                    .background(
                        RoundedRectangle(cornerRadius: style.cornerRadius * scale)
                            .fill(bg)
                    )
                    .overlay(
                        // A subtle dashed outline appears while dragging
                        // so the user knows the subtitle box is being
                        // repositioned (cleared as soon as the gesture
                        // ends via onChange(of:) of dragBaseline).
                        RoundedRectangle(cornerRadius: style.cornerRadius * scale)
                            .strokeBorder(
                                dragBaseline == nil
                                    ? Color.clear
                                    : Color.white.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                            )
                    )
                    .position(
                        x: CGFloat(style.horizontalPositionFraction) * g.size.width,
                        y: CGFloat(style.verticalPositionFraction) * g.size.height
                    )
                    .gesture(subtitleDragGesture(containerSize: g.size))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    /// DragGesture that repositions the subtitle box by updating the
    /// style's horizontal/vertical position fractions. Frozen
    /// baseline lets us compute absolute positions as
    /// `baseline + translationFraction` without drift.
    private func subtitleDragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragBaseline == nil {
                    dragBaseline = (
                        document.subtitleStyle.horizontalPositionFraction,
                        document.subtitleStyle.verticalPositionFraction
                    )
                }
                guard let base = dragBaseline,
                      containerSize.width > 0, containerSize.height > 0 else { return }
                let dx = Double(value.translation.width / containerSize.width)
                let dy = Double(value.translation.height / containerSize.height)
                document.updateSubtitleStyle { s in
                    s.horizontalPositionFraction = max(0.05, min(0.95, base.h + dx))
                    s.verticalPositionFraction = max(0.05, min(0.95, base.v + dy))
                }
            }
            .onEnded { _ in dragBaseline = nil }
    }

    private func anchor(for a: HorizontalAlignment) -> Alignment {
        switch a {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    /// Cheap, stable identity for the primary timeline. If nothing in
    /// this string changes, the composition is identical.
    private var timelineKey: String {
        let parts = document.tracks
            .first(where: { $0.kind == .video })?
            .segments.map { seg -> String in
                let e = seg.effects
                let vp = document.visualEffects[seg.id]?.rawValue ?? ""
                return "\(seg.id.uuidString):\(seg.range.startSeconds)-\(seg.range.endSeconds):\(seg.volumeLevel):\(e.brightness)/\(e.contrast)/\(e.saturation):r\(e.rotation)h\(e.flipHorizontal ? 1 : 0)v\(e.flipVertical ? 1 : 0):fi\(e.audioFadeInDuration)fo\(e.audioFadeOutDuration):\(vp)"
            }
            ?? []
        let overlayKey = document.textOverlays.map {
            "\($0.id.uuidString):\($0.text):\($0.startSeconds)-\($0.endSeconds):\($0.positionX),\($0.positionY):\($0.fontSizeRel):\($0.colorR),\($0.colorG),\($0.colorB)"
        }.joined(separator: ";")
        let transitionKey = document.transitions
            .sorted(by: { $0.key.uuidString < $1.key.uuidString })
            .map { "\($0.key.uuidString):\($0.value)" }
            .joined(separator: ",")
        // Overlay (PiP) track: include every overlay segment's anchor,
        // trim range, shape, and freeTransform so shape/opacity edits
        // invalidate the cached AVPlayerItem.
        let pipKey = document.tracks
            .filter { $0.kind == .overlay }
            .flatMap { $0.segments }
            .map { seg -> String in
                let l = seg.pipLayout
                let ft = seg.freeTransform
                return "\(seg.id.uuidString):\(seg.placementOffset ?? -1):\(seg.range.startSeconds)-\(seg.range.endSeconds):\(l?.shape.rawValue ?? "-"):\(l?.corner.rawValue ?? "-"):\(l?.sizeFraction ?? 0):\(l?.insetFraction ?? 0):ft\(ft?.opacity ?? -1)"
            }
            .joined(separator: ";")
        return parts.joined(separator: "|") + "##" + overlayKey + "##" + transitionKey + "##" + pipKey
    }

    private func refreshItem() {
        let key = timelineKey
        if key == cachedKey, document.player.currentItem != nil {
            ppTrace("refreshItem skip — cached key matches and player has item")
            return
        }

        let primary = document.tracks
            .first(where: { $0.kind == .video })?
            .segments ?? []
        let overlays = document.tracks
            .filter { $0.kind == .overlay }
            .flatMap { $0.segments }

        ppTrace("refreshItem primary=\(primary.count) overlays=\(overlays.count) media=\(document.manifest.media.count) cachedKey=\(cachedKey.prefix(60)) newKey=\(key.prefix(60))")

        if primary.isEmpty {
            ppTrace("refreshItem empty primary — clearing player item")
            document.player.pause()
            document.player.replaceCurrentItem(with: nil)
            cachedKey = ""
            return
        }

        // Log each resolved media path so black-preview cases can be
        // pinpointed to missing files (e.g. Photos-library URLs that
        // don't survive a project re-open).
        for seg in primary {
            if let m = document.manifest.media.first(where: { $0.id == seg.sourceVideoID }) {
                let url = IOSCompositionBuilder.resolveURL(for: m, projectRoot: document.store.projectRoot)
                let exists = FileManager.default.fileExists(atPath: url.path)
                ppTrace("  seg=\(seg.id.uuidString.prefix(8)) src=\(m.sourcePath.suffix(40)) proxy=\(m.derived.proxyRelativePath ?? "-") resolved=\(url.path.suffix(40)) exists=\(exists)")
            } else {
                ppTrace("  seg=\(seg.id.uuidString.prefix(8)) MISSING MEDIA RECORD sourceVideoID=\(seg.sourceVideoID)")
            }
        }

        guard let item = IOSCompositionBuilder.build(
            primarySegments: primary,
            overlaySegments: overlays,
            manifest: document.manifest,
            projectRoot: document.store.projectRoot,
            visualEffects: document.visualEffects,
            textOverlays: document.textOverlays,
            transitions: document.transitions
        ) else {
            ppTrace("refreshItem build returned nil — clearing player item")
            document.player.pause()
            document.player.replaceCurrentItem(with: nil)
            cachedKey = ""
            return
        }

        ppTrace("refreshItem build ok — replacing player item duration=\(CMTimeGetSeconds(item.asset.duration))")
        document.player.replaceCurrentItem(with: item)
        cachedKey = key
    }
}

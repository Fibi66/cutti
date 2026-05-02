import SwiftUI
import AVKit
import AVFoundation

/// Post-picker preview sheet: the user scrubs a just-picked video and
/// drags a pair of handles to choose the subrange to add. Shown after
/// PHPicker returns but before `ProjectDocument.importVideo` runs, so
/// users can cut out the boring lead-in/tail without first landing a
/// full-length clip on the timeline. Tapping "添加" returns the chosen
/// TimeRange; "取消" throws the temp file away.
struct TrimPreviewSheet: View {
    let sourceURL: URL
    /// Called with the chosen [startSeconds, endSeconds] when the user
    /// confirms. Nil when they cancel.
    let onDone: (ClosedRange<Double>?) -> Void

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startSec: Double = 0
    @State private var endSec: Double = 0
    @State private var currentSec: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("取消") { finish(nil) }
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("选择片段")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    finish(startSec...endSec)
                } label: {
                    Text("添加").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.95, green: 0.25, blue: 0.35)))
                }
                .disabled(duration <= 0)
            }

            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            trimStrip

            HStack {
                Text(format(startSec))
                Spacer()
                Text(L("已选 %@", format(endSec - startSec)))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(format(endSec))
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .onAppear { load() }
        .onDisappear { teardown() }
    }

    /// Range handles drawn inside a 44pt-tall strip. Dragging the left
    /// handle clamps to [0, endSec-0.3]; the right clamps to
    /// [startSec+0.3, duration]. The fill between the handles is the
    /// active selection; a thin blue line is the live playback cursor.
    private var trimStrip: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let toX: (Double) -> CGFloat = { t in
                guard duration > 0 else { return 0 }
                return CGFloat(t / duration) * w
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.10))

                // Selection band
                Rectangle()
                    .fill(Color(red: 0.95, green: 0.25, blue: 0.35).opacity(0.30))
                    .frame(width: max(0, toX(endSec) - toX(startSec)), height: 44)
                    .offset(x: toX(startSec))

                // Playback cursor
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: 44)
                    .offset(x: max(0, min(w - 2, toX(currentSec))))

                handle(at: toX(startSec)) { dx in
                    let newT = max(0, min(endSec - 0.3, startSec + Double(dx / w) * duration))
                    startSec = newT
                    seek(to: newT)
                }
                handle(at: toX(endSec)) { dx in
                    let newT = max(startSec + 0.3, min(duration, endSec + Double(dx / w) * duration))
                    endSec = newT
                    seek(to: newT)
                }
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func handle(at x: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(Color(red: 0.95, green: 0.25, blue: 0.35))
            .frame(width: 10, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1.2)
            )
            .offset(x: x - 5, y: -4)
            .gesture(
                DragGesture()
                    .onChanged { v in onDrag(v.translation.width) }
            )
    }

    private func load() {
        let p = AVPlayer(url: sourceURL)
        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let d = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(d)
                await MainActor.run {
                    duration = secs
                    startSec = 0
                    endSec = secs
                }
            }
        }
        let interval = CMTime(seconds: 1.0/30, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            let s = CMTimeGetSeconds(t)
            currentSec = s
            // Loop within the selected range so the user can audition
            // their trim without manual seeking.
            if s >= endSec - 0.05 {
                p.seek(to: CMTime(seconds: startSec, preferredTimescale: 600))
            }
        }
        p.play()
        player = p
    }

    private func teardown() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        player?.pause()
        player = nil
    }

    private func seek(to t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func finish(_ range: ClosedRange<Double>?) {
        teardown()
        onDone(range)
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite else { return "00:00.0" }
        let s = Int(t)
        let ms = Int((t - Double(s)) * 10)
        return String(format: "%02d:%02d.%d", s / 60, s % 60, ms)
    }
}

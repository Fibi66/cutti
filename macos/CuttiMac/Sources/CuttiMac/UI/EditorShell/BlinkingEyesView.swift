import SwiftUI

/// The full Cutti brand mark — eyebrows, eyes, and the small nose hook —
/// rendered as a vector from the canonical SVG (see
/// ``CuttiLogoPathData``). Only the eyes animate: they blink in sync
/// every 3 seconds while ``isAnimating`` is `true`. Eyebrows and nose
/// stay perfectly still so the mark keeps its identity while the eyes
/// squint.
///
/// ### Sizing
/// ``targetHeight`` controls the rendered height of the full mark in
/// points; width falls out of the native 1064 × 1094 SVG viewBox so
/// proportions stay perfect at any size.
///
/// ### Animation gating
/// ``isAnimating`` defaults to `true` so the old processing-indicator
/// use site keeps working. Set it to `false` for the identity mark
/// embedded in role tags: the eyes then sit open and only blink while
/// the agent is actively working.
struct BlinkingEyesView: View {
    /// Controls whether the eyes blink. When `false`, they rest open.
    var isAnimating: Bool = true

    /// Rendered height of the complete logo (brows + eyes + nose), in
    /// points. 13.68 pt is the previous 34.2 pt indicator shrunk by
    /// 60 % per the designer's request. Callers override for smaller
    /// inline variants (e.g. a ~11 pt role-tag mark).
    var targetHeight: CGFloat = 13.68

    @State private var blinking: Bool = false
    @State private var loopTask: Task<Void, Never>?

    /// How long the eyes stay fully open before each blink.
    private let idleBeforeBlink: Double = 2.7
    /// Half of the close→open animation. The close and open phases
    /// each take this long, giving a total blink motion of ~0.3 s.
    private let halfBlink: Double = 0.15
    /// Delay before the *first* blink after the view appears so the
    /// eyes are visibly open when the bubble first shows up.
    private let initialDelay: Double = 0.8
    /// Vertical scale at the moment the lids meet. Kept > 0 so a hair-
    /// thin line remains visible, mimicking a closed eyelid rather
    /// than a void.
    private let closedScaleY: CGFloat = 0.08

    private var targetWidth: CGFloat {
        targetHeight * (CuttiLogoPathData.viewBox.width
                        / CuttiLogoPathData.viewBox.height)
    }

    var body: some View {
        ZStack {
            CuttiLogoPartsShape(parts: [.rightBrow, .leftBrow, .nose])
                .fill(Color.white)
            CuttiLogoPartsShape(parts: [.leftEye])
                .fill(Color.white)
                .scaleEffect(
                    x: 1.0,
                    y: blinking ? closedScaleY : 1.0,
                    anchor: CuttiLogoPathData.anchor(of: .leftEye)
                )
            CuttiLogoPartsShape(parts: [.rightEye])
                .fill(Color.white)
                .scaleEffect(
                    x: 1.0,
                    y: blinking ? closedScaleY : 1.0,
                    anchor: CuttiLogoPathData.anchor(of: .rightEye)
                )
        }
        .frame(width: targetWidth, height: targetHeight)
        .accessibilityHidden(true)
        .onAppear {
            if isAnimating { startLoop() }
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                startLoop()
            } else {
                stopLoop()
            }
        }
        .onDisappear {
            stopLoop()
        }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { await runBlinkLoop() }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        // Snap lids back open so a mid-blink cancel doesn't leave the
        // eyes frozen shut.
        withAnimation(.easeInOut(duration: halfBlink)) {
            blinking = false
        }
    }

    @MainActor
    private func runBlinkLoop() async {
        do {
            try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        } catch {
            return
        }
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: halfBlink)) {
                blinking = true
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(halfBlink * 1_000_000_000))
            } catch {
                return
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: halfBlink)) {
                blinking = false
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(idleBeforeBlink * 1_000_000_000))
            } catch {
                return
            }
        }
    }
}

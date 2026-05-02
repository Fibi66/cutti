// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

extension TimelineDock {

    // MARK: - Zoom slider

    /// Full composed timeline duration, clamped to at least the minimum
    /// viewport. Computed directly from the model so the toolbar zoom
    /// controls work on the very first click — before the GeometryReader
    /// has had a chance to cache anything. Matches the `composedDuration`
    /// expression used inside the render GeometryReader.
    var fitSeconds: Double {
        let composed = segments.isEmpty
            ? durationSeconds
            : segments.reduce(0) { $0 + quantizedSeconds($1.durationSeconds) }
        return max(Self.minViewportSeconds, composed)
    }

    /// True when the full timeline already fits below `minViewportSeconds`
    /// (e.g. a 0.5 s clip). In that case there's no zoom range to drag
    /// through, so the ± buttons and slider are disabled to avoid the
    /// "controls respond but nothing moves" trap.
    var zoomUnavailable: Bool {
        fitSeconds <= Self.minViewportSeconds + 0.0001
    }

    /// Current effective viewport length in seconds (how much of the
    /// timeline the user can see at once). Resolves the persisted
    /// `viewportSeconds` sentinel and clamps into
    /// `[minViewportSeconds, fitSeconds]`.
    var resolvedViewportSeconds: Double {
        let target = viewportSeconds <= 0 ? fitSeconds : viewportSeconds
        return max(Self.minViewportSeconds, min(fitSeconds, target))
    }

    /// Zoom so that `seconds` of timeline fill the viewport. Non-finite
    /// inputs are ignored so a NaN from e.g. a zero-width slider drag
    /// can never land in AppStorage. If the caller asked for at least
    /// the full material, collapse to the fit sentinel so future zooms
    /// keep tracking "fit" as the material grows/shrinks.
    func setViewportSeconds(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let fit = fitSeconds
        let clamped = max(Self.minViewportSeconds, min(fit, seconds))
        viewportSeconds = clamped >= fit - 0.001 ? 0 : clamped
    }

    /// Compact zoom control in the timeline toolbar. The model is
    /// "visible duration" — pressing `+` halves the seconds of timeline
    /// shown, `-` doubles them. This is relative to the material, so
    /// one click always makes a clearly-visible difference no matter
    /// whether the clip is 5 min or 1 h. Double-click either magnifier
    /// to reset to fit-to-view.
    ///
    /// Zoom is applied instantly (no `withAnimation`). Animating was
    /// tempting for "feel" but it makes `contentWidth` (a SwiftUI
    /// layout property) and the ScrollView's scroll offset (driven by
    /// `scrollProxy.scrollTo`) interpolate on two independent tracks —
    /// they are not frame-synchronized, so during the animation the
    /// playhead visibly drifts left/right and the scrollbar "spins".
    /// Snapping both in a single frame is the only way to keep the
    /// playhead truly fixed on screen while the material expands
    /// around it, which is how every pro NLE (FCP, Premiere, Resolve)
    /// does this gesture.
    var zoomSlider: some View {
        HStack(spacing: 6) {
            Button {
                // Zoom out = see more seconds. Clamped to fit via
                // setViewportSeconds; once we hit fit the sentinel is
                // stored and further `-` clicks are no-ops.
                setViewportSeconds(resolvedViewportSeconds * Self.zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .tooltip(L("Zoom out (2×)"))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .disabled(zoomUnavailable)
            .onTapGesture(count: 2) {
                viewportSeconds = 0 // fit
            }

            // Custom drag-based slider. Using SwiftUI's `Slider`
            // (a wrapped `NSSlider`) caused the timeline toolbar to
            // steal first responder after any click, which in turn
            // swallowed Space and even routed click events oddly so
            // the Play button felt unresponsive. A plain
            // `Rectangle` + `DragGesture` has no NSResponder
            // behaviour and is all we need here.
            //
            // The slider is log-scaled over visible duration: 0% = fit
            // (whole timeline), 100% = minViewportSeconds. Log scale
            // matches the ±2× buttons' feel — equal travel = equal
            // zoom factor — so dragging halfway doesn't dump the user
            // straight into millisecond territory on a long clip.
            GeometryReader { geo in
                let w = geo.size.width
                let fit = fitSeconds
                // When fit collapses to the minimum (very short clips)
                // the log range is 0. Guard so we don't divide by zero
                // and leak a NaN into the thumb position or the drag
                // handler.
                let logRange = log(fit / Self.minViewportSeconds)
                let hasRange = logRange > 0.0001 && w > 0
                let pct: Double = {
                    guard hasRange else { return 0 }
                    return max(0, min(1, log(fit / resolvedViewportSeconds) / logRange))
                }()
                let thumbX = pct * w

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(EditorShellStyle.borderSubtle)
                        .frame(height: 3)

                    Capsule()
                        .fill(EditorShellStyle.accentSolid.opacity(hasRange ? 0.7 : 0.3))
                        .frame(width: thumbX, height: 3)

                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(EditorShellStyle.borderSubtle, lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                        .offset(x: thumbX - 5)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .opacity(hasRange ? 1 : 0.4)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard hasRange else { return }
                            let x = max(0, min(w, value.location.x))
                            let p = Double(x / w)
                            let seconds = fit / exp(p * logRange)
                            // Slider drag tracks continuously — no
                            // withAnimation wrapper so motion follows
                            // the finger 1:1.
                            setViewportSeconds(seconds)
                        }
                )
            }
            .frame(width: 90, height: 16)
            .tooltip(L("Timeline zoom — drag to see between whole clip and ~1 s"))
            .allowsHitTesting(!zoomUnavailable)

            Button {
                // Zoom in = see fewer seconds.
                setViewportSeconds(resolvedViewportSeconds / Self.zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .tooltip(L("Zoom in (2×)"))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .disabled(zoomUnavailable)
            .onTapGesture(count: 2) {
                viewportSeconds = 0 // fit
            }
        }
    }

}

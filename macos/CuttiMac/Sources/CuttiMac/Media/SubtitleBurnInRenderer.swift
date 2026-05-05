import AppKit
import CoreGraphics
import CuttiKit
import CoreImage
import CoreText
import Foundation

/// Renders a single subtitle cue into a `CIImage` that can be composited
/// over a video frame. Thread-safe (stateless); safe to call from the
/// Core Image filtering queue used by `AVMutableVideoComposition`.
struct SubtitleBurnInRenderer: Sendable {

    struct Cue: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
        /// Optional translated line for bilingual rendering. When both
        /// `secondaryText` and `style.bilingual` are present, the
        /// renderer draws two lines. Nil or empty keeps single-line
        /// behaviour even on a bilingual style so a cue that failed to
        /// translate still burns in cleanly.
        let secondaryText: String?
        /// Optional per-run rich-text styling for `text`. Nil = render
        /// `text` uniformly with the cue's `SubtitleStyle` (the fast
        /// path every pre-rich-text cue exercises). When non-nil, the
        /// renderer walks the runs and applies per-range overrides on
        /// top of the baseline cue style. The secondary (translation)
        /// line is always rendered plain, even when the primary line
        /// carries runs — translations don't have a per-run model.
        let runs: [SubtitleRun]?
        /// Optional per-cue style override. Nil = render with the
        /// renderer's project-wide `style` (back-compat path every cue
        /// takes when the user hasn't customised this cue
        /// individually). When non-nil, every set field replaces the
        /// matching field on `style` at render time so burn-in matches
        /// the viewer overlay pixel-for-pixel.
        let styleOverride: SubtitleCueStyleOverride?

        init(
            startSeconds: Double,
            endSeconds: Double,
            text: String,
            secondaryText: String? = nil,
            runs: [SubtitleRun]? = nil,
            styleOverride: SubtitleCueStyleOverride? = nil
        ) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
            self.secondaryText = secondaryText
            self.runs = runs
            self.styleOverride = styleOverride
        }
    }

    let cues: [Cue]
    /// Project-wide baseline style. Per-cue overrides on
    /// `Cue.styleOverride` layer on top of this at render time; a cue
    /// with `styleOverride == nil` renders identically to the pre-V1 path.
    let style: SubtitleStyle
    /// Final render size (points). Determines font scale and max width.
    let renderSize: CGSize

    /// Resolve the effective style for a cue (global × per-cue override).
    /// Cues without an override return the global baseline unchanged so
    /// the fast path is bit-stable.
    func effectiveStyle(for cue: Cue) -> SubtitleStyle {
        cue.styleOverride?.applied(to: style) ?? style
    }

    /// Pick the cue active at `time` (or nil if none).
    func cue(at time: Double) -> Cue? {
        // Linear scan is fine for realistic transcript sizes (< ~2000 cues).
        // Upgrade to binary search if this ever becomes a hot spot.
        cues.first { time >= $0.startSeconds && time < $0.endSeconds }
    }

    /// Produce an overlay image for the given playhead time, or nil if no cue
    /// is active or the text is empty.
    func overlay(at time: Double) -> CIImage? {
        guard let cue = cue(at: time) else { return nil }
        let primary = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty else { return nil }
        let effective = effectiveStyle(for: cue)
        let secondary = cue.secondaryText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let secondary, !secondary.isEmpty, effective.bilingual != nil {
            return renderBilingual(primary: primary, secondary: secondary, runs: cue.runs, style: effective)
        }
        return render(text: primary, runs: cue.runs, style: effective)
    }

    // MARK: - Rendering

    /// Scale factor from canonical 1080p to actual render size.
    var heightScale: CGFloat {
        guard renderSize.height > 0 else { return 1 }
        return renderSize.height / 1080.0
    }

    /// Render the given text into a CIImage positioned on a transparent
    /// canvas matching `renderSize`.
    ///
    /// When `runs` is non-nil and consistent with `text`, per-run style
    /// overrides are applied on top of the baseline cue style. When
    /// `runs` is nil (or drifted — fallback), the whole line renders
    /// uniformly using the cue style.
    func render(text: String, runs: [SubtitleRun]? = nil, style explicitStyle: SubtitleStyle? = nil) -> CIImage? {
        let style = explicitStyle ?? self.style
        let scale = heightScale
        let fontSize = max(8, CGFloat(style.fontSizePoints) * scale)
        let padH = CGFloat(style.backgroundPaddingHorizontal) * scale
        let padV = CGFloat(style.backgroundPaddingVertical) * scale
        let corner = CGFloat(style.cornerRadius) * scale
        let shadowBlur = CGFloat(style.shadowBlurRadius) * scale
        let shadowOffsetY = CGFloat(style.shadowOffsetY) * scale
        // For stroke/canvas sizing, use the max possible stroke width across
        // runs (run may upscale font). We approximate with the baseline
        // stroke plus a headroom factor driven by the largest run size
        // multiplier — keeps glyphs away from canvas edges even when a run
        // scales up.
        let maxSizeMultiplier = Self.maxRunSizeMultiplier(runs)
        let strokeWidth = CGFloat(style.strokeWidthFraction) * fontSize * CGFloat(maxSizeMultiplier)

        let attributed = makeAttributedString(
            text: text,
            runs: runs,
            baseFontSize: fontSize,
            style: style
        )

        let maxTextWidth = max(10, renderSize.width * CGFloat(style.maxWidthFraction))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            nil
        )

        // Layout box for the text (excluding padding/stroke inflation).
        // Inflate a bit to accommodate the stroke outline without clipping.
        let textPadding = max(1, strokeWidth + shadowBlur + 2)
        let textBoxSize = CGSize(
            width: ceil(suggested.width + textPadding * 2),
            height: ceil(suggested.height + textPadding * 2)
        )

        // Background box includes background padding.
        let bgSize = CGSize(
            width: textBoxSize.width + padH * 2,
            height: textBoxSize.height + padV * 2
        )

        // Full canvas includes shadow spill.
        let shadowPad = ceil(shadowBlur + abs(shadowOffsetY)) + 2
        let canvasSize = CGSize(
            width: ceil(bgSize.width + shadowPad * 2),
            height: ceil(bgSize.height + shadowPad * 2)
        )

        guard let bitmap = makeBitmapContext(size: canvasSize) else { return nil }

        // Draw shadow only when configured.
        if shadowBlur > 0.1 && style.shadowColor.alpha > 0.001 {
            bitmap.setShadow(
                offset: CGSize(width: 0, height: -shadowOffsetY),
                blur: shadowBlur,
                color: style.shadowColor.cg
            )
        }

        // Background rect.
        let bgRect = CGRect(
            x: shadowPad,
            y: shadowPad,
            width: bgSize.width,
            height: bgSize.height
        )
        if style.backgroundColor.alpha > 0.001 {
            bitmap.setFillColor(style.backgroundColor.cg)
            let path = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            bitmap.addPath(path)
            bitmap.fillPath()
        }

        // Clear the shadow so text isn't double-shadowed.
        bitmap.setShadow(offset: .zero, blur: 0)

        // Draw text centered within bgRect, adjusted for the text padding.
        let textRect = CGRect(
            x: bgRect.origin.x + padH + textPadding,
            y: bgRect.origin.y + padV + textPadding,
            width: suggested.width,
            height: suggested.height
        )
        let path = CGPath(rect: textRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        drawHighlightBackgrounds(in: ctFrame, textRect: textRect, context: bitmap)
        CTFrameDraw(ctFrame, bitmap)

        guard let cgImage = bitmap.makeImage() else { return nil }

        // Position overlay on the full-frame canvas.
        let overlay = CIImage(cgImage: cgImage)
        let positioned = positioningTransform(
            overlayWidth: canvasSize.width,
            overlayHeight: canvasSize.height,
            style: style
        )
        return overlay.transformed(by: positioned)
    }

    /// Render two stacked lines (primary + secondary translation) into a
    /// single overlay. Visual parity with `SubtitleOverlay`'s SwiftUI
    /// bilingual path so preview and burn-in match pixel-for-pixel (same
    /// font, stroke, shadow, background geometry — the only new
    /// variables are the secondary font size and the inter-line gap).
    ///
    /// The function is defensive: missing/empty inputs or a nil
    /// `style.bilingual` degrade to single-line rendering rather than
    /// returning nil, so a failed translation or an upstream caller that
    /// didn't check the style still produces a readable subtitle.
    ///
    /// `runs`, when non-nil, applies per-range styling to the *primary*
    /// line only — the translation stays uniformly styled.
    func renderBilingual(
        primary: String,
        secondary: String,
        runs: [SubtitleRun]? = nil,
        style explicitStyle: SubtitleStyle? = nil
    ) -> CIImage? {
        let style = explicitStyle ?? self.style
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondary = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else {
            return trimmedSecondary.isEmpty ? nil : render(text: trimmedSecondary, style: style)
        }
        guard !trimmedSecondary.isEmpty else { return render(text: trimmedPrimary, runs: runs, style: style) }
        guard let bilingual = style.bilingual else { return render(text: trimmedPrimary, runs: runs, style: style) }

        let scale = heightScale
        let primaryFontSize = max(8, CGFloat(style.fontSizePoints) * scale)
        let secondaryFontSize = max(
            8,
            primaryFontSize * CGFloat(bilingual.clampedSecondarySizeRatio)
        )
        let lineGap = primaryFontSize * CGFloat(bilingual.clampedLineSpacingFraction)

        let padH = CGFloat(style.backgroundPaddingHorizontal) * scale
        let padV = CGFloat(style.backgroundPaddingVertical) * scale
        let corner = CGFloat(style.cornerRadius) * scale
        let shadowBlur = CGFloat(style.shadowBlurRadius) * scale
        let shadowOffsetY = CGFloat(style.shadowOffsetY) * scale
        // Primary stroke bounds the combined outline (primary ≥ secondary
        // in size, and stroke is proportional to font size). Include the
        // max run size multiplier so a scaled-up run doesn't overflow
        // the clip rect.
        let maxSizeMultiplier = Self.maxRunSizeMultiplier(runs)
        let strokeWidth = CGFloat(style.strokeWidthFraction) * primaryFontSize * CGFloat(maxSizeMultiplier)

        guard let primaryLine = layoutLine(
                text: trimmedPrimary, fontSize: primaryFontSize, runs: runs, style: style),
              let secondaryLine = layoutLine(
                text: trimmedSecondary, fontSize: secondaryFontSize, runs: nil, style: style)
        else {
            // Framesetter refused both — fall back to single-line so the
            // viewer still sees the primary text instead of a blank frame.
            return render(text: trimmedPrimary, runs: runs, style: style)
        }

        let textWidth = max(primaryLine.size.width, secondaryLine.size.width)
        let textHeight = primaryLine.size.height + lineGap + secondaryLine.size.height

        let textPadding = max(1, strokeWidth + shadowBlur + 2)
        let textBoxSize = CGSize(
            width: ceil(textWidth + textPadding * 2),
            height: ceil(textHeight + textPadding * 2)
        )
        let bgSize = CGSize(
            width: textBoxSize.width + padH * 2,
            height: textBoxSize.height + padV * 2
        )
        let shadowPad = ceil(shadowBlur + abs(shadowOffsetY)) + 2
        let canvasSize = CGSize(
            width: ceil(bgSize.width + shadowPad * 2),
            height: ceil(bgSize.height + shadowPad * 2)
        )

        guard let bitmap = makeBitmapContext(size: canvasSize) else { return nil }

        if shadowBlur > 0.1 && style.shadowColor.alpha > 0.001 {
            bitmap.setShadow(
                offset: CGSize(width: 0, height: -shadowOffsetY),
                blur: shadowBlur,
                color: style.shadowColor.cg
            )
        }

        let bgRect = CGRect(
            x: shadowPad,
            y: shadowPad,
            width: bgSize.width,
            height: bgSize.height
        )
        if style.backgroundColor.alpha > 0.001 {
            bitmap.setFillColor(style.backgroundColor.cg)
            let path = CGPath(
                roundedRect: bgRect,
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            )
            bitmap.addPath(path)
            bitmap.fillPath()
        }

        bitmap.setShadow(offset: .zero, blur: 0)

        // `placement == .below` means the *secondary* line sits below
        // the primary → primary is the visually-top line. `.above` is
        // the mirror. Core Graphics' origin is bottom-left, so the
        // visually-bottom line has the smaller y.
        let topLine: LineLayout
        let bottomLine: LineLayout
        switch bilingual.placement {
        case .below:
            topLine = primaryLine
            bottomLine = secondaryLine
        case .above:
            topLine = secondaryLine
            bottomLine = primaryLine
        }

        let textOriginX = bgRect.origin.x + padH + textPadding
        let textOriginY = bgRect.origin.y + padV + textPadding
        let bottomRect = CGRect(
            x: textOriginX + (textWidth - bottomLine.size.width) / 2,
            y: textOriginY,
            width: bottomLine.size.width,
            height: bottomLine.size.height
        )
        let topRect = CGRect(
            x: textOriginX + (textWidth - topLine.size.width) / 2,
            y: textOriginY + bottomLine.size.height + lineGap,
            width: topLine.size.width,
            height: topLine.size.height
        )

        drawLine(topLine, in: topRect, context: bitmap)
        drawLine(bottomLine, in: bottomRect, context: bitmap)

        guard let cgImage = bitmap.makeImage() else { return nil }
        let overlay = CIImage(cgImage: cgImage)
        let positioned = positioningTransform(
            overlayWidth: canvasSize.width,
            overlayHeight: canvasSize.height,
            style: style
        )
        return overlay.transformed(by: positioned)
    }

    /// Internal layout result for a single text line — paired with
    /// `drawLine` so the bilingual path can measure-all-then-draw-all
    /// (which is required for correct stacking: we need the combined
    /// size before picking the canvas geometry).
    private struct LineLayout {
        let framesetter: CTFramesetter
        let length: Int
        let size: CGSize
    }

    private func layoutLine(
        text: String,
        fontSize: CGFloat,
        runs: [SubtitleRun]? = nil,
        style explicitStyle: SubtitleStyle? = nil
    ) -> LineLayout? {
        let style = explicitStyle ?? self.style
        let attributed = makeAttributedString(
            text: text, runs: runs, baseFontSize: fontSize, style: style)
        let maxTextWidth = max(10, renderSize.width * CGFloat(style.maxWidthFraction))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            nil
        )
        guard suggested.width > 0, suggested.height > 0 else { return nil }
        return LineLayout(
            framesetter: framesetter,
            length: attributed.length,
            size: CGSize(
                width: ceil(suggested.width),
                height: ceil(suggested.height)
            )
        )
    }

    // MARK: - Attributed string construction

    /// Build the `NSAttributedString` used by both the mono-line and
    /// bilingual paths. When `runs == nil` the whole string gets a
    /// single uniform attribute set derived from `style` — identical to
    /// the pre-rich-text behavior. When `runs != nil` and the runs'
    /// concatenated text matches `text`, per-run style overrides are
    /// applied on top of the base attrs; if they drift (should never
    /// happen in practice thanks to `SubtitleEntry.hasConsistentRuns`),
    /// we fall back to uniform styling so the cue never blanks out.
    func makeAttributedString(
        text: String,
        runs: [SubtitleRun]?,
        baseFontSize: CGFloat,
        style explicitStyle: SubtitleStyle? = nil
    ) -> NSAttributedString {
        let style = explicitStyle ?? self.style
        let baseAttrs = baseAttributes(fontSize: baseFontSize, style: style)
        guard
            let runs,
            SubtitleRunEditor.plainText(runs) == text,
            !runs.isEmpty
        else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }
        let result = NSMutableAttributedString()
        for run in runs {
            let attrs = mergeAttributes(
                base: baseAttrs,
                with: run.style,
                baseFontSize: baseFontSize,
                style: style
            )
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }

    /// Attributes that every run inherits before its own overrides are
    /// merged in. Keeping this in one place means the baseline mirrors
    /// the pre-rich-text path exactly.
    private func baseAttributes(fontSize: CGFloat, style explicitStyle: SubtitleStyle? = nil) -> [NSAttributedString.Key: Any] {
        let style = explicitStyle ?? self.style
        let ctFont = CTFontCreateWithName(style.fontName as CFString, fontSize, nil)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: style.textColor.cg
        ]
        let strokeWidth = CGFloat(style.strokeWidthFraction) * fontSize
        if strokeWidth > 0.01 && style.strokeColor.alpha > 0.001 {
            attrs[.strokeColor] = style.strokeColor.cg
            // Negative = stroke + fill. CoreText stroke width is
            // expressed as a percentage of font size (×-100 by
            // convention).
            attrs[.strokeWidth] = -(CGFloat(style.strokeWidthFraction) * 100.0)
        }
        return attrs
    }

    /// Apply a per-run override on top of the baseline attributes. Nil
    /// fields in `override` leave the base attribute alone.
    private func mergeAttributes(
        base: [NSAttributedString.Key: Any],
        with override: SubtitleRunStyle,
        baseFontSize: CGFloat,
        style explicitStyle: SubtitleStyle? = nil
    ) -> [NSAttributedString.Key: Any] {
        let style = explicitStyle ?? self.style
        var attrs = base

        // --- Font (family / size / weight) ---
        let runFontSize = baseFontSize * CGFloat(override.sizeMultiplier ?? 1.0)
        let familyName = override.fontName ?? style.fontName
        if override.fontName != nil
            || override.sizeMultiplier != nil
            || override.weight != nil
        {
            attrs[.font] = Self.makeFont(
                familyName: familyName,
                size: runFontSize,
                weight: override.weight
            )
        }

        // --- Fill color ---
        if let textColor = override.textColor {
            attrs[.foregroundColor] = textColor.cg
        }

        // --- Stroke (color / width) ---
        let baseStrokeFraction = style.strokeWidthFraction
        let effectiveFraction = override.strokeWidthFractionOverride ?? baseStrokeFraction
        let effectiveStrokeColor = override.strokeColor ?? style.strokeColor
        let runStrokeWidth = CGFloat(effectiveFraction) * runFontSize
        if runStrokeWidth > 0.01 && effectiveStrokeColor.alpha > 0.001 {
            attrs[.strokeColor] = effectiveStrokeColor.cg
            attrs[.strokeWidth] = -(CGFloat(effectiveFraction) * 100.0)
        } else {
            // Explicit clear: base had a stroke but this run disabled
            // it via `strokeWidthFractionOverride == 0` or a zero-alpha
            // color. Remove the keys so CoreText skips the stroke pass.
            attrs.removeValue(forKey: .strokeColor)
            attrs.removeValue(forKey: .strokeWidth)
        }

        // --- Underline ---
        if override.underline == true {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = (override.textColor ?? style.textColor).cg
        }

        // --- Highlight background (pill) ---
        // Tagged with a custom key. Actual drawing happens in a second
        // pass before CTFrameDraw (see drawHighlightBackgrounds) because
        // CoreText does not honor NSAttributedString.Key.backgroundColor
        // during CTFrameDraw — we need post-layout glyph geometry to
        // compute pill rects.
        if let bg = override.highlightBackground, bg.alpha > 0.001 {
            attrs[Self.highlightBGAttrKey] = bg.cg
        }

        return attrs
    }

    /// Custom attribute key carrying the CGColor for a run's
    /// `highlightBackground`. Picked up by `drawHighlightBackgrounds`.
    static let highlightBGAttrKey = NSAttributedString.Key("cuttiHighlightBG")

    /// Walk a laid-out CTFrame and fill a rounded-rect pill behind every
    /// glyph run carrying `highlightBGAttrKey`. Draws directly into
    /// `context` before `CTFrameDraw` so glyphs land on top of the pill.
    ///
    /// The pill covers the run's typographic bounds (ascent+descent
    /// above/below baseline, start→end X via line offset lookup) padded
    /// slightly for visual weight. Rounded corner scales with the run
    /// height so small text still reads as a pill.
    fileprivate func drawHighlightBackgrounds(
        in ctFrame: CTFrame,
        textRect: CGRect,
        context: CGContext
    ) {
        let lines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: lines.count), &origins)

        context.saveGState()
        defer { context.restoreGState() }

        let horizontalPad: CGFloat = 2
        let verticalPad: CGFloat = 1

        for (lineIdx, line) in lines.enumerated() {
            let origin = origins[lineIdx]
            let baselineY = textRect.origin.y + origin.y
            let lineLeftX = textRect.origin.x + origin.x

            guard let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for glyphRun in glyphRuns {
                let attrs = CTRunGetAttributes(glyphRun) as NSDictionary
                guard let raw = attrs[Self.highlightBGAttrKey as NSString] else { continue }
                // CFTypeRef / CGColor round-trip via Any. Force-cast is
                // safe because mergeAttributes only ever stores CGColor
                // under this key; skip defensively if not.
                let cgColor: CGColor = raw as! CGColor

                let runRange = CTRunGetStringRange(glyphRun)
                guard runRange.length > 0 else { continue }

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                _ = CTRunGetTypographicBounds(
                    glyphRun,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    &leading
                )

                let startOffset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                let endOffset = CTLineGetOffsetForStringIndex(
                    line,
                    runRange.location + runRange.length,
                    nil
                )
                let width = max(1, endOffset - startOffset)

                let pillRect = CGRect(
                    x: lineLeftX + startOffset - horizontalPad,
                    y: baselineY - descent - verticalPad,
                    width: width + horizontalPad * 2,
                    height: ascent + descent + verticalPad * 2
                )
                let corner = min(pillRect.height / 2, 8)

                context.setFillColor(cgColor)
                let path = CGPath(
                    roundedRect: pillRect,
                    cornerWidth: corner,
                    cornerHeight: corner,
                    transform: nil
                )
                context.addPath(path)
                context.fillPath()
            }
        }
    }

    /// Build a CTFont honoring optional weight. Uses NSFont when a
    /// weight is requested so the system's standard weight mapping
    /// (regular / medium / semibold / bold / heavy / black) is
    /// respected. Falls back to `CTFontCreateWithName` when only a
    /// family override is needed — that path matches the pre-rich-text
    /// behaviour exactly and keeps the "no runs" code path bit-stable.
    private static func makeFont(
        familyName: String,
        size: CGFloat,
        weight: SubtitleRunStyle.Weight?
    ) -> CTFont {
        guard let weight else {
            return CTFontCreateWithName(familyName as CFString, size, nil)
        }
        let nsWeight: NSFont.Weight = {
            switch weight {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            }
        }()
        // Prefer the named family at the requested weight. If the
        // family doesn't ship the weight, NSFontManager returns nil and
        // we fall back to the system font at the requested weight so
        // the render never blanks out.
        let nsFont: NSFont
        if let faced = NSFontManager.shared.font(
            withFamily: familyName,
            traits: weight.isBoldish ? [.boldFontMask] : [],
            weight: Int(weight.nsFontManagerWeight),
            size: size
        ) {
            nsFont = faced
        } else {
            nsFont = NSFont.systemFont(ofSize: size, weight: nsWeight)
        }
        return nsFont as CTFont
    }

    /// Largest size multiplier seen across `runs`. Used to size the
    /// canvas so scaled-up runs don't get clipped. Defaults to 1.0 when
    /// no runs or all runs have a nil multiplier.
    private static func maxRunSizeMultiplier(_ runs: [SubtitleRun]?) -> Double {
        guard let runs, !runs.isEmpty else { return 1.0 }
        var maxVal = 1.0
        for run in runs {
            if let mult = run.style.sizeMultiplier, mult > maxVal {
                maxVal = mult
            }
        }
        return maxVal
    }

    private func drawLine(_ line: LineLayout, in rect: CGRect, context: CGContext) {
        let path = CGPath(rect: rect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(
            line.framesetter,
            CFRange(location: 0, length: line.length),
            path,
            nil
        )
        drawHighlightBackgrounds(in: ctFrame, textRect: rect, context: context)
        CTFrameDraw(ctFrame, context)
    }

    // MARK: - Positioning

    /// Translate the overlay so it sits at the configured position within the
    /// render frame. Core Image's coordinate space has (0,0) at the bottom-left.
    ///
    /// Positioning is computed from `horizontalPositionFraction` (center-X) and
    /// `verticalPositionFraction` (center-Y, top→bottom). The `alignment`
    /// field only affects internal text alignment, not placement.
    func positioningTransform(overlayWidth: CGFloat, overlayHeight: CGFloat, style explicitStyle: SubtitleStyle? = nil) -> CGAffineTransform {
        let style = explicitStyle ?? self.style
        let hFrac = max(0, min(1, CGFloat(style.horizontalPositionFraction)))
        let xCenter = hFrac * renderSize.width
        let xOrigin = xCenter - overlayWidth / 2

        let vFrac = max(0, min(1, CGFloat(style.verticalPositionFraction)))
        let centerFromTop = vFrac * renderSize.height
        let centerFromBottom = renderSize.height - centerFromTop
        let yOrigin = centerFromBottom - overlayHeight / 2

        return CGAffineTransform(translationX: xOrigin, y: yOrigin)
    }

    // MARK: - Bitmap helpers

    private func makeBitmapContext(size: CGSize) -> CGContext? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Text antialiasing.
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        return ctx
    }
}

// MARK: - SubtitleRunStyle.Weight → NSFontManager bridging

private extension SubtitleRunStyle.Weight {
    /// Font-manager weight values roughly align with AppKit's
    /// documented mapping: 5 = regular, 6 = medium, 8 = semibold,
    /// 9 = bold, 10 = heavy, 11 = black. NSFontManager uses these when
    /// picking a concrete face within a family.
    var nsFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        case .black: return 11
        }
    }

    var isBoldish: Bool {
        switch self {
        case .regular, .medium, .semibold: return false
        case .bold, .heavy, .black: return true
        }
    }
}


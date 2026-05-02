import CoreGraphics
import CoreImage
import CoreText
import Foundation
import CuttiKit

/// Renders a YouTube-style chapter progress bar into a `CIImage` that
/// can be composited over a video frame.
///
/// Layout:
///   • A horizontal bar near the bottom (or top) of the frame, divided
///     into N segments proportional to chapter durations, with thin gaps
///     between chapters.
///   • Filled portion of the active chapter shows playback progress
///     within that chapter.
///   • Current chapter title centered just above (bottom anchor) or
///     below (top anchor) the bar.
///   • Optional translucent panel drawn behind the whole title+bar
///     region so light frames don't swallow it.
///
/// Times are in **edited-timeline seconds** (post-cut), matching how
/// the player's playhead is reported.
struct ChapterBarBurnInRenderer: Sendable {

    let chapters: [VideoChapter]
    /// Total duration of the edited timeline in seconds. Used as the
    /// denominator for bar segment widths so the bar always covers the
    /// full width regardless of small floating-point gaps in chapter
    /// math.
    let totalSeconds: Double
    /// Final render size in points. Determines bar height/y-position.
    let renderSize: CGSize
    /// User-adjustable appearance + position. Defaults to
    /// `ChapterBarStyle.default`.
    let style: ChapterBarStyle

    init(
        chapters: [VideoChapter],
        totalSeconds: Double,
        renderSize: CGSize,
        style: ChapterBarStyle = .default
    ) {
        self.chapters = chapters
        self.totalSeconds = totalSeconds
        self.renderSize = renderSize
        self.style = style
    }

    // MARK: - Layout constants (canonical 1080p)

    private static let barHeight1080p: CGFloat = 6
    private static let barHorizontalInset1080p: CGFloat = 64
    private static let barEdgeInset1080p: CGFloat = 8
    private static let titleGap1080p: CGFloat = 18
    private static let segmentGap1080p: CGFloat = 4
    private static let cornerRadius1080p: CGFloat = 3
    private static let panelPaddingX1080p: CGFloat = 32
    private static let panelPaddingY1080p: CGFloat = 14
    private static let panelCornerRadius1080p: CGFloat = 10

    private static let trackColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.30)
    private static let pastChapterColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.85)
    private static let currentChapterFillColor = CGColor(red: 1, green: 0.30, blue: 0.30, alpha: 1.0)
    private static let titleShadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)

    // MARK: - Public

    /// Pick the chapter active at `time`, or nil if no chapters / out of range.
    func chapter(at time: Double) -> (index: Int, chapter: VideoChapter)? {
        guard !chapters.isEmpty else { return nil }
        let clamped = max(0, min(time, totalSeconds))
        for (i, c) in chapters.enumerated() {
            if clamped < c.endSeconds { return (i, c) }
        }
        return (chapters.count - 1, chapters[chapters.count - 1])
    }

    /// Produce an overlay image for the given playhead time, or nil if
    /// nothing should be drawn (no chapters / unusable size).
    func overlay(at time: Double) -> CIImage? {
        guard !chapters.isEmpty,
              totalSeconds > 0,
              renderSize.width > 8,
              renderSize.height > 8
        else { return nil }
        return render(at: max(0, min(time, totalSeconds)))
    }

    // MARK: - Render

    private var heightScale: CGFloat {
        guard renderSize.height > 0 else { return 1 }
        return renderSize.height / 1080.0
    }

    private func render(at time: Double) -> CIImage? {
        let scale = heightScale
        let barHeight = max(2, Self.barHeight1080p * scale)
        let hInset = Self.barHorizontalInset1080p * scale
        let edgeInset = Self.barEdgeInset1080p * scale
        let segGap = max(1, Self.segmentGap1080p * scale)
        let corner = Self.cornerRadius1080p * scale
        let titleGap = Self.titleGap1080p * scale
        let titleFontSize = max(10, CGFloat(style.fontSize) * scale)
        let panelPadX = Self.panelPaddingX1080p * scale
        let panelPadY = Self.panelPaddingY1080p * scale
        let panelCorner = Self.panelCornerRadius1080p * scale

        let canvasSize = renderSize
        guard let bitmap = makeBitmapContext(size: canvasSize) else { return nil }

        let barLeft = hInset
        let barRight = canvasSize.width - hInset
        let barWidth = max(1, barRight - barLeft)
        // CG coords: (0,0) bottom-left.
        // Bottom anchor: bar sits edgeInset from bottom, title above.
        // Top anchor:   bar sits edgeInset from top,    title below.
        let barY: CGFloat
        let titleBaselineY: CGFloat
        switch style.anchor {
        case .bottom:
            barY = edgeInset
            titleBaselineY = barY + barHeight + titleGap
        case .top:
            barY = canvasSize.height - edgeInset - barHeight
            // title descent needs a bit of padding; baseline = barY - gap - fontSize
            titleBaselineY = barY - titleGap - titleFontSize
        }

        // Measure a representative title line for panel sizing. Each
        // chapter will later draw its own title centered on its segment,
        // but the panel is sized once from the tallest line.
        let activeIndex = chapter(at: time)?.index ?? 0
        let activeChapter = chapters[activeIndex]
        let hasAnyTitle = chapters.contains {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let titleLineHeight: CGFloat = hasAnyTitle
            ? measureTitle("Hg", fontSize: titleFontSize).height
            : 0

        // Background panel rect wrapping the bar + (optional) title row.
        // Panel width matches the bar since per-segment titles are
        // clipped to their own segment width.
        let panelWidth = barWidth + panelPadX * 2
        let panelHeight: CGFloat = {
            let stack = barHeight + (hasAnyTitle ? titleGap + titleLineHeight : 0)
            return stack + panelPadY * 2
        }()
        let panelX = (canvasSize.width - panelWidth) / 2
        let panelY: CGFloat
        switch style.anchor {
        case .bottom:
            panelY = barY - panelPadY
        case .top:
            panelY = (titleBaselineY) - panelPadY
        }
        let panelRect = CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

        // Draw the background panel (bgColor × opacity).
        let effectiveAlpha = max(0, min(1, style.backgroundColor.alpha * style.backgroundOpacity))
        if effectiveAlpha > 0.001 {
            let panelColor = CGColor(
                red: CGFloat(style.backgroundColor.red),
                green: CGFloat(style.backgroundColor.green),
                blue: CGFloat(style.backgroundColor.blue),
                alpha: CGFloat(effectiveAlpha)
            )
            bitmap.setFillColor(panelColor)
            bitmap.addPath(CGPath(roundedRect: panelRect, cornerWidth: panelCorner, cornerHeight: panelCorner, transform: nil))
            bitmap.fillPath()
        }

        let barRect = CGRect(x: barLeft, y: barY, width: barWidth, height: barHeight)

        // Track background
        bitmap.setFillColor(Self.trackColor)
        bitmap.addPath(CGPath(roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        bitmap.fillPath()

        // Per-chapter sub-rects.
        let activeProgress: Double
        if activeChapter.durationSeconds > 0 {
            activeProgress = max(0, min(1, (time - activeChapter.startSeconds) / activeChapter.durationSeconds))
        } else {
            activeProgress = 1
        }

        for (i, c) in chapters.enumerated() {
            let startFrac = c.startSeconds / totalSeconds
            let endFrac = c.endSeconds / totalSeconds
            var segLeft = barLeft + barWidth * startFrac
            var segRight = barLeft + barWidth * endFrac
            if i > 0 { segLeft += segGap / 2 }
            if i < chapters.count - 1 { segRight -= segGap / 2 }
            guard segRight > segLeft else { continue }
            let segRect = CGRect(x: segLeft, y: barY, width: segRight - segLeft, height: barHeight)

            if i < activeIndex {
                bitmap.setFillColor(Self.pastChapterColor)
                bitmap.addPath(CGPath(roundedRect: segRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
                bitmap.fillPath()
            } else if i == activeIndex {
                let fillWidth = max(0, segRect.width * CGFloat(activeProgress))
                if fillWidth > 0.5 {
                    let fillRect = CGRect(x: segRect.minX, y: segRect.minY, width: fillWidth, height: segRect.height)
                    bitmap.setFillColor(Self.currentChapterFillColor)
                    bitmap.addPath(CGPath(roundedRect: fillRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
                    bitmap.fillPath()
                }
            }
        }

        // Per-chapter titles. Each title sits centered horizontally on
        // its own segment so the full chapter list is readable at a
        // glance (not just the active one above the whole bar). Titles
        // are truncated with an ellipsis if they exceed the segment
        // width.
        if hasAnyTitle {
            for (i, c) in chapters.enumerated() {
                let segTitle = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segTitle.isEmpty else { continue }
                let startFrac = c.startSeconds / totalSeconds
                let endFrac = c.endSeconds / totalSeconds
                var segLeft = barLeft + barWidth * startFrac
                var segRight = barLeft + barWidth * endFrac
                if i > 0 { segLeft += segGap / 2 }
                if i < chapters.count - 1 { segRight -= segGap / 2 }
                let segW = max(0, segRight - segLeft)
                guard segW > 8 else { continue }
                let segCenterX = (segLeft + segRight) / 2
                drawTitle(
                    segTitle,
                    bitmap: bitmap,
                    fontSize: titleFontSize,
                    centerX: segCenterX,
                    baselineY: titleBaselineY,
                    maxWidth: segW
                )
            }
        }

        guard let cgImage = bitmap.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Helpers

    private func measureTitle(_ text: String, fontSize: CGFloat) -> CGRect {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    private func drawTitle(
        _ text: String,
        bitmap: CGContext,
        fontSize: CGFloat,
        centerX: CGFloat,
        baselineY: CGFloat,
        maxWidth: CGFloat
    ) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let titleCG = CGColor(
            red: CGFloat(style.fontColor.red),
            green: CGFloat(style.fontColor.green),
            blue: CGFloat(style.fontColor.blue),
            alpha: CGFloat(max(0, min(1, style.fontColor.alpha)))
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: titleCG
        ]
        // Truncate with ellipsis if the rendered line would exceed
        // `maxWidth`. CoreText does not auto-truncate, so we use
        // CTLineCreateTruncatedLine with a single-ellipsis token.
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if bounds.width > maxWidth {
            let ellipsis = NSAttributedString(string: "…", attributes: attributes)
            let ellipsisLine = CTLineCreateWithAttributedString(ellipsis)
            if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsisLine) {
                line = truncated
                bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            }
        }
        let x = centerX - bounds.width / 2

        bitmap.saveGState()
        bitmap.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 6,
            color: Self.titleShadowColor
        )
        bitmap.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, bitmap)
        bitmap.restoreGState()
    }

    private func makeBitmapContext(size: CGSize) -> CGContext? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}


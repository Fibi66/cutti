import SwiftUI
import CuttiKit

extension Notification.Name {
    /// Posted when a UI element wants the host layout to present the media picker.
    static let cuttiRequestMediaImport = Notification.Name("cuttiRequestMediaImport")
}

/// CapCut-style timeline. No lane labels. Single primary clip strip
/// with frame thumbnails, leading utility tiles (mute original, set
/// cover), trailing "+" to add more clips, and an "Add audio"
/// placeholder row below. Red playhead across the whole thing;
/// pinch-zoom; drag-to-scrub anywhere in the timeline area.
struct TimelineCanvas: View {
    @EnvironmentObject private var document: ProjectDocument
    @State private var pixelsPerSecond: CGFloat = 36
    @GestureState private var zoomScale: CGFloat = 1.0
    private var scaledPPS: CGFloat { pixelsPerSecond * zoomScale }

    var body: some View {
        GeometryReader { outer in
            let half = outer.size.width / 2
            // Leading pad so content-x 0 (start of utility tiles) sits
            // at viewport center when scroll offset is 0; if the viewport
            // is narrower than the utility prefix we fall back to 0.
            let leadingPad = max(0, half - leadingTileWidth)
            ZStack {
                CenteredTimelineScroll(
                    currentTime: Binding(
                        get: { document.currentTime },
                        set: { document.seek(toSeconds: $0) }
                    ),
                    pixelsPerSecond: scaledPPS,
                    leadingPad: leadingPad,
                    trailingPad: half
                ) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            timeRuler
                            primaryClipRow
                            primaryWaveformRow
                            subtitleTrackRow
                            audioTrackRows
                        }
                        .padding(.vertical, 6)
                    }
                }
                // Fixed playhead pinned at viewport center.
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .position(x: half, y: outer.size.height / 2)
                    .allowsHitTesting(false)
            }
            .background(Color.black)
            .gesture(
                MagnificationGesture()
                    .updating($zoomScale) { v, s, _ in s = v }
                    .onEnded { v in pixelsPerSecond = max(8, min(200, pixelsPerSecond * v)) }
            )
            .onAppear { primeWaveforms() }
            .onChange(of: document.tracks) { _ in primeWaveforms() }
        }
    }

    // MARK: - Layout pieces

    /// Tick-style ruler. Tick spacing adapts to current zoom so labels
    /// stay ~50–80pt apart.
    private var timeRuler: some View {
        let total = max(document.primaryDurationSeconds, 10)
        let width = CGFloat(total) * scaledPPS + leadingTileWidth + 200
        let tickEverySec = chooseTickInterval(pixelsPerSecond: scaledPPS)

        return Canvas { ctx, size in
            var t: Double = 0
            while t <= total + tickEverySec {
                let x = leadingTileWidth + CGFloat(t) * scaledPPS
                let label = format(t)
                ctx.draw(
                    Text(label).font(.system(size: 10)).foregroundColor(.white.opacity(0.55)),
                    at: CGPoint(x: x, y: size.height / 2)
                )
                t += tickEverySec
            }
        }
        .frame(width: width, height: 18)
    }

    /// Main track row: mute toggle + cover tile + clips + add-clip "+".
    private var primaryClipRow: some View {
        HStack(alignment: .center, spacing: 4) {
            UtilityTile(icon: "speaker.slash.fill", label: "关闭原声") {
                document.togglePrimaryTrackMuted()
            }
            CoverTile(document: document)

            clipStrip

            AddClipTile {
                NotificationCenter.default.post(name: .cuttiRequestMediaImport, object: nil)
            }
        }
        .frame(height: 52)
    }

    /// Audio placeholder row matching CapCut's "+ 添加音频".
    private var addAudioPlaceholder: some View {
        let width = max(240, CGFloat(document.primaryDurationSeconds) * scaledPPS)
        return HStack {
            Spacer().frame(width: leadingTileWidth)
            HStack {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                Text("添加音频")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: width, height: 28, alignment: .leading)
            .padding(.leading, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
            )
        }
    }

    /// Slim waveform strip directly under the primary clip row,
    /// visualising the audio bundled with the primary video track.
    /// Even when the user hasn't added music, this gives immediate
    /// CapCut-style audio context for trimming/scrubbing.
    private var primaryWaveformRow: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: leadingTileWidth)
            WaveformStrip(
                segments: primarySegments,
                pixelsPerSecond: scaledPPS,
                height: 22,
                tint: Color(red: 0.20, green: 0.65, blue: 0.95)
            )
        }
    }

    /// Subtitle cue track. Flattens every primary-track cue and draws
    /// a small teal chip per cue so the user sees at a glance where
    /// their subtitles live (matching CapCut's dedicated subtitle
    /// row). Tap a chip to seek the playhead to that cue. When no
    /// cues exist, the row is hidden so it doesn't eat vertical
    /// space on fresh projects.
    @ViewBuilder
    private var subtitleTrackRow: some View {
        let cues = document.composedTranscriptCues
        if !cues.isEmpty {
            HStack(spacing: 0) {
                Spacer().frame(width: leadingTileWidth)
                ZStack(alignment: .topLeading) {
                    // Invisible spacer pinning the row width to the
                    // primary-track duration so the chip layout lines
                    // up with the clips above.
                    Color.clear
                        .frame(
                            width: max(120, CGFloat(document.primaryDurationSeconds) * scaledPPS),
                            height: 20
                        )
                    ForEach(cues, id: \.id) { cue in
                        let x = CGFloat(cue.composedStart) * scaledPPS
                        let w = max(
                            6,
                            CGFloat(max(0.2, cue.composedEnd - cue.composedStart)) * scaledPPS
                        )
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0.15, green: 0.75, blue: 0.70).opacity(0.85))
                            .frame(width: w, height: 18)
                            .overlay(
                                Text(cue.text)
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(width: w, height: 18, alignment: .leading)
                                    .allowsHitTesting(false)
                            )
                            .offset(x: x, y: 1)
                            .onTapGesture {
                                document.seek(toSeconds: cue.composedStart)
                            }
                    }
                }
            }
        }
    }

    /// Any non-primary `.audio` tracks rendered below the primary
    /// waveform row. When no audio track exists, we fall back to the
    /// "+ 添加音频" placeholder so the timeline still offers an
    /// affordance.
    @ViewBuilder
    private var audioTrackRows: some View {
        let audioTracks = document.tracks.filter { $0.kind == .audio }
        if audioTracks.isEmpty {
            addAudioPlaceholder
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(audioTracks, id: \.id) { t in
                    HStack(spacing: 0) {
                        Spacer().frame(width: leadingTileWidth)
                        DraggableAudioRow(
                            segments: t.segments,
                            pixelsPerSecond: scaledPPS,
                            height: 28,
                            tint: Color(red: 0.95, green: 0.75, blue: 0.20)
                        )
                    }
                }
            }
        }
    }

    private func primeWaveforms() {
        let store = WaveformStore.shared
        let waveDir = document.store.projectRoot.appending(path: "media/waveforms")
        var seen = Set<UUID>()
        for track in document.tracks where track.kind == .video || track.kind == .audio {
            for seg in track.segments {
                let mid = seg.sourceVideoID
                guard seen.insert(mid).inserted else { continue }
                guard let record = document.manifest.media.first(where: { $0.id == mid })
                else { continue }
                let url: URL = {
                    if let proxy = record.derived.proxyRelativePath {
                        return document.store.projectRoot.appendingPathComponent(proxy)
                    }
                    return URL(fileURLWithPath: record.sourcePath)
                }()
                store.prime(mediaID: mid, sourceURL: url, waveformDir: waveDir)
            }
        }
    }

    private var clipStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(primarySegments.enumerated()), id: \.element.id) { i, seg in
                SegmentChip(
                    segment: seg,
                    index: i,
                    allSegments: primarySegments,
                    pixelsPerSecond: scaledPPS,
                    isSelected: document.selectedSegmentID == seg.id
                )
            }
        }
    }

    private var primarySegments: [TimelineSegment] {
        document.tracks.first(where: { $0.kind == .video })?.segments ?? []
    }

    // MARK: - Playhead (removed — now rendered as a fixed overlay by
    // the body, and seeking is driven by CenteredTimelineScroll's
    // UIScrollView offset so drags scroll the content instead of
    // repositioning a free-floating playhead.)

    // MARK: - Helpers

    /// Horizontal pixel offset that the primary timeline starts at,
    /// accounting for the two utility tiles (mute + cover) that
    /// precede the first clip in the CapCut layout.
    private var leadingTileWidth: CGFloat { 52 + 52 + 8 }

    private func chooseTickInterval(pixelsPerSecond: CGFloat) -> Double {
        // Try to keep ticks 60–100 pt apart.
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 30, 60, 120]
        for c in candidates where pixelsPerSecond * CGFloat(c) >= 60 { return c }
        return 120
    }

    private func format(_ s: Double, includeMillis: Bool = false) -> String {
        let total = max(0, s)
        let t = Int(total)
        if includeMillis {
            let ms = Int((total - Double(t)) * 100)
            return String(format: "%02d:%02d.%02d", t / 60, t % 60, ms)
        }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - Utility tiles

private struct UtilityTile: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(L(label))
                    .font(.system(size: 10))
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }
}

/// Cover-frame tile. Renders the currently-picked cover thumbnail
/// (looked up via ProjectDocument.resolveComposedTime +
/// ThumbnailStore) and presents the CoverPickerSheet on tap so the
/// user can change the cover by scrubbing through the timeline.
private struct CoverTile: View {
    @ObservedObject var document: ProjectDocument
    @StateObject private var thumbs = ThumbnailStore.shared
    @State private var present = false

    var body: some View {
        Button { present = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                if let t = document.coverTimeSeconds,
                   let resolved = document.resolveComposedTime(t),
                   let url = mediaURL(for: resolved.sourceVideoID),
                   let img = thumbs.thumbnail(
                       for: url,
                       mediaID: resolved.sourceVideoID,
                       atSeconds: resolved.sourceSeconds
                   )
                {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    // Subtle "封面" label on a gradient footer.
                    VStack {
                        Spacer()
                        Text("封面")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.55))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                        Text("设置封面")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 52)
        }
        .sheet(isPresented: $present) {
            CoverPickerSheet()
                .environmentObject(document)
                .presentationDetents([.large])
        }
    }

    private func mediaURL(for mediaID: UUID) -> URL? {
        guard let record = document.manifest.media.first(where: { $0.id == mediaID })
        else { return nil }
        if let proxy = record.derived.proxyRelativePath {
            return document.store.projectRoot.appendingPathComponent(proxy)
        }
        return URL(fileURLWithPath: record.sourcePath)
    }
}

private struct AddClipTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 52)
                .background(Color.white.opacity(0.12))
        }
    }
}

// MARK: - Segment chip (CapCut-style with thumbnails)

private struct SegmentChip: View {
    @EnvironmentObject var document: ProjectDocument
    @EnvironmentObject var appState: AppState
    @StateObject private var thumbs = ThumbnailStore.shared

    let segment: TimelineSegment
    let index: Int
    let allSegments: [TimelineSegment]
    let pixelsPerSecond: CGFloat
    let isSelected: Bool

    @State private var draftStartDelta: Double = 0
    @State private var draftEndDelta: Double = 0
    @State private var reorderDX: CGFloat = 0
    @State private var isReordering: Bool = false
    @State private var transitionEditorPresented: Bool = false

    private var currentStart: Double { segment.range.startSeconds + draftStartDelta }
    private var currentEnd: Double { segment.range.endSeconds + draftEndDelta }
    private var currentDuration: Double { max(0.1, currentEnd - currentStart) }

    private func chipWidth(_ s: TimelineSegment) -> CGFloat {
        max(20, CGFloat(max(0.1, s.range.endSeconds - s.range.startSeconds)) * pixelsPerSecond)
    }

    var body: some View {
        let width = max(20, CGFloat(currentDuration) * pixelsPerSecond)
        ZStack(alignment: .topLeading) {
            thumbnailStrip(width: width)
                .frame(width: width, height: 52)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(
                            isReordering ? Color.pink :
                                (isSelected ? Color.white : Color.clear),
                            lineWidth: 2
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture { document.selectSegment(segment.id) }
                .gesture(reorderGesture)
                .contextMenu { segmentContextMenu }

            if isSelected && !isReordering {
                trimHandle(side: .leading)
                trimHandle(side: .trailing)
                    .offset(x: width - 8, y: 0)
            }

            segmentBadges
                .offset(x: 4, y: 34)
                .allowsHitTesting(false)

            if document.hasTransition(for: segment.id),
               index < allSegments.count - 1 {
                transitionIndicator
                    .offset(x: width - 10, y: 18)
                    .onTapGesture {
                        document.selectSegment(segment.id)
                        transitionEditorPresented = true
                    }
            }
        }
        .offset(x: reorderDX)
        .scaleEffect(isReordering ? 1.06 : 1.0)
        .shadow(color: isReordering ? .black.opacity(0.6) : .clear,
                radius: isReordering ? 6 : 0)
        .zIndex(isReordering ? 10 : 0)
        .animation(.easeOut(duration: 0.15), value: isReordering)
        .sheet(isPresented: $transitionEditorPresented) {
            TransitionDurationSheet(segmentID: segment.id)
                .environmentObject(document)
                .presentationDetents([.height(220)])
        }
    }

    /// Long-press context menu for the segment. Selects the segment
    /// first so the document's mutators operate on it, then surfaces
    /// the common verbs. Mirrors the ⌘C / ⌘X / ⌘V / ⌘D / ⌘B / ⌫
    /// keyboard shortcuts so touch-only users can reach every action.
    @ViewBuilder
    private var segmentContextMenu: some View {
        Group {
            Button {
                document.selectSegment(segment.id)
                document.splitAtPlayhead()
            } label: { Label("在播放头分割", systemImage: "scissors") }

            Button {
                document.selectSegment(segment.id)
                document.duplicateSelectedSegment()
            } label: { Label("复制副本", systemImage: "plus.square.on.square") }

            Divider()

            Button {
                document.selectSegment(segment.id)
                document.copySelectedSegment(to: appState)
            } label: { Label("拷贝", systemImage: "doc.on.doc") }

            Button {
                document.selectSegment(segment.id)
                document.cutSelectedSegment(to: appState)
            } label: { Label("剪切", systemImage: "scissors.badge.ellipsis") }

            if appState.segmentClipboard != nil {
                Button {
                    document.selectSegment(segment.id)
                    document.pasteClipboardSegment(from: appState)
                } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
            }

            Divider()

            Button {
                document.selectSegment(segment.id)
                let newLevel = segment.volumeLevel > 0.01 ? 0.0 : 1.0
                document.setSelectedSegmentVolume(newLevel)
            } label: {
                Label(
                    segment.volumeLevel > 0.01 ? "静音" : "取消静音",
                    systemImage: segment.volumeLevel > 0.01 ? "speaker.slash" : "speaker.wave.2"
                )
            }

            Button {
                document.selectSegment(segment.id)
                if segment.linkedSegmentID == nil {
                    document.detachSelectedAudio()
                } else {
                    document.reattachSelectedAudio()
                }
            } label: {
                Label(
                    segment.linkedSegmentID == nil ? "分离音频" : "合并音频",
                    systemImage: segment.linkedSegmentID == nil
                        ? "waveform.path.badge.plus"
                        : "waveform.path.badge.minus"
                )
            }

            Button {
                document.toggleTransition(for: segment.id)
            } label: {
                Label(
                    document.hasTransition(for: segment.id) ? "取消转场" : "加入转场",
                    systemImage: document.hasTransition(for: segment.id)
                        ? "rectangle.2.swap"
                        : "rectangle.2.fill.swap"
                )
            }

            Divider()

            Button(role: .destructive) {
                document.selectSegment(segment.id)
                document.deleteSelectedSegment()
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// Long-press (~0.35s) then drag to reorder within the primary
    /// track. On release the horizontal delta is mapped to a signed
    /// index offset by walking outward from this chip's position and
    /// consuming neighbour widths until the drag centre crosses each
    /// neighbour's midpoint.
    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { state in
                if case .second(true, let drag) = state {
                    if !isReordering {
                        isReordering = true
                        document.selectSegment(segment.id)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    reorderDX = drag?.translation.width ?? 0
                }
            }
            .onEnded { state in
                defer {
                    isReordering = false
                    reorderDX = 0
                }
                guard case .second(true, let drag) = state, let d = drag else { return }
                let offset = computeReorderOffset(dx: d.translation.width)
                if offset != 0 {
                    document.moveSelectedSegment(offset: offset)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
    }

    private func computeReorderOffset(dx: CGFloat) -> Int {
        guard allSegments.indices.contains(index) else { return 0 }
        var target = index
        if dx > 0 {
            var acc: CGFloat = 0
            for i in (index + 1)..<allSegments.count {
                let w = chipWidth(allSegments[i])
                if dx > acc + w / 2 {
                    target = i
                    acc += w
                } else { break }
            }
        } else if dx < 0 {
            var acc: CGFloat = 0
            for i in stride(from: index - 1, through: 0, by: -1) {
                let w = chipWidth(allSegments[i])
                if -dx > acc + w / 2 {
                    target = i
                    acc += w
                } else { break }
            }
        }
        return target - index
    }

    /// Strip of periodically-sampled thumbnails so a long clip shows
    /// its content at a glance.
    private func thumbnailStrip(width: CGFloat) -> some View {
        let tileCount = max(1, Int(width / 36))
        return HStack(spacing: 0) {
            ForEach(0..<tileCount, id: \.self) { i in
                let fraction = Double(i) / Double(max(tileCount, 1))
                let srcTime = currentStart + fraction * currentDuration
                ThumbnailView(
                    mediaID: segment.sourceVideoID,
                    sourceSeconds: srcTime
                )
                .frame(width: width / CGFloat(tileCount), height: 52)
            }
        }
    }

    /// Small CapCut-style pills rendered at the chip's bottom-left
    /// to flag non-default properties at a glance:
    ///   - speed != 1x  →  "2x" / "0.5x"
    ///   - volume == 0  →  speaker.slash icon (original audio muted)
    /// Kept to a tight horizontal stack so it never overflows the
    /// chip on narrow zoom levels.
    @ViewBuilder
    private var segmentBadges: some View {
        HStack(spacing: 3) {
            if abs(segment.speedRate - 1.0) > 0.001 {
                badgeLabel(formatSpeed(segment.speedRate))
            }
            if segment.volumeLevel <= 0.001 {
                badgeIcon("speaker.slash.fill")
            }
        }
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.black.opacity(0.75)))
    }

    private func badgeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.75)))
    }

    /// Format speed as "2x" for integers, "1.5x" for halves, and
    /// stripped trailing zero otherwise so "0.50x" doesn't clutter
    /// a tight chip.
    private func formatSpeed(_ r: Double) -> String {
        if abs(r - r.rounded()) < 0.01 {
            return "\(Int(r.rounded()))x"
        }
        return String(format: "%.1fx", r)
    }

    /// Small diamond-with-chevrons glyph rendered where two chips
    /// meet when the left segment has an active transition. The
    /// icon sits half on the current chip and half on the next
    /// one (via the outgoing `offset(x: width - 10)`) mimicking
    /// CapCut's "|>|" transition marker.
    private var transitionIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
                .frame(width: 20, height: 20)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
        }
    }

    private enum Side { case leading, trailing }

    private func trimHandle(side: Side) -> some View {
        let maxEnd = document.sourceDuration(for: segment)
        return RoundedRectangle(cornerRadius: 1)
            .fill(Color.white)
            .frame(width: 8, height: 52)
            .overlay(
                Rectangle().fill(Color.black.opacity(0.4)).frame(width: 2, height: 16)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let delta = Double(v.translation.width / pixelsPerSecond)
                        switch side {
                        case .leading:
                            let newStart = min(max(segment.range.startSeconds + delta, 0),
                                               segment.range.endSeconds - 0.1)
                            draftStartDelta = newStart - segment.range.startSeconds
                        case .trailing:
                            let newEnd = min(max(segment.range.endSeconds + delta,
                                                 segment.range.startSeconds + 0.1),
                                             maxEnd)
                            draftEndDelta = newEnd - segment.range.endSeconds
                        }
                    }
                    .onEnded { _ in
                        document.selectSegment(segment.id)
                        document.trimSelectedSegment(newStart: currentStart, newEnd: currentEnd)
                        draftStartDelta = 0
                        draftEndDelta = 0
                    }
            )
    }
}

private struct ThumbnailView: View {
    @EnvironmentObject var document: ProjectDocument
    @StateObject private var store = ThumbnailStore.shared

    let mediaID: UUID
    let sourceSeconds: Double

    var body: some View {
        Group {
            if let url = mediaURL(),
               let img = store.thumbnail(for: url, mediaID: mediaID, atSeconds: sourceSeconds) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.15)
            }
        }
    }

    private func mediaURL() -> URL? {
        guard let record = document.manifest.media.first(where: { $0.id == mediaID }) else { return nil }
        if let proxy = record.derived.proxyRelativePath {
            return document.store.projectRoot.appendingPathComponent(proxy)
        }
        return URL(fileURLWithPath: record.sourcePath)
    }
}

// MARK: - Waveform strip

/// Renders the union of `segments` as a single horizontal waveform
/// strip. Each segment's playable window is mapped back into its
/// source envelope (from `WaveformStore`), scaled to the segment's
/// on-screen width. Gaps between segment starts are drawn as empty
/// space so the strip aligns with the video clip row above it.
private struct WaveformStrip: View {
    @EnvironmentObject var document: ProjectDocument
    @StateObject private var store = WaveformStore.shared
    let segments: [TimelineSegment]
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \TimelineSegment.id) { seg in
                chip(for: seg)
            }
        }
    }

    @ViewBuilder
    private func chip(for seg: TimelineSegment) -> some View {
        let width = max(CGFloat(2), CGFloat(max(0.1, seg.range.endSeconds - seg.range.startSeconds)) * pixelsPerSecond)
        let sourceDur = document.manifest.media
            .first(where: { $0.id == seg.sourceVideoID })?.analysis?.durationSeconds ?? seg.range.endSeconds
        WaveformSegmentView(
            envelope: store.envelope(for: seg.sourceVideoID),
            sourceDuration: sourceDur,
            startSeconds: seg.range.startSeconds,
            endSeconds: seg.range.endSeconds,
            tint: tint
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Detached-audio row that positions each chip at its
/// `placementOffset` along the timeline (instead of packing them
/// into an HStack) and lets the user drag a chip horizontally to
/// reposition it. The drag converts pixel translation back to
/// seconds via `pixelsPerSecond`, then calls
/// `ProjectDocument.setAudioPlacement` on release. While dragging
/// we only mutate a local @State so the gesture stays buttery at
/// 60 fps without re-rendering the whole timeline on every frame;
/// a `beginInteractiveEdit`/`endInteractiveEdit` pair coalesces
/// the final commit into a single undo step.
private struct DraggableAudioRow: View {
    @EnvironmentObject var document: ProjectDocument
    @StateObject private var store = WaveformStore.shared
    let segments: [TimelineSegment]
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let tint: Color

    @State private var dragging: UUID?
    @State private var dragDeltaSeconds: Double = 0
    /// Whether the current drag is snapped to a guide (playhead or a
    /// primary-track segment boundary). When true, the chip gets a
    /// brief highlight so the user knows an alignment point was hit.
    @State private var isSnapped: Bool = false

    /// Candidate snap targets for the current drag, captured at
    /// gesture-start to avoid recomputing them on every finger move.
    /// Includes t=0, the playhead, and every primary-track segment
    /// boundary.
    @State private var snapTargets: [Double] = []

    /// In-flight trim deltas in source-media seconds. `trimLeftDelta`
    /// is applied to both `range.startSeconds` AND the on-screen
    /// offset so the right edge stays put visually; `trimRightDelta`
    /// only grows/shrinks the width.
    @State private var trimLeftDelta: Double = 0
    @State private var trimRightDelta: Double = 0
    @State private var trimming: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(
                width: max(40, CGFloat(document.primaryDurationSeconds) * pixelsPerSecond + 400),
                height: height
            )
            ForEach(segments, id: \TimelineSegment.id) { seg in
                chip(for: seg)
            }
        }
    }

    /// Compute the snap targets lazily: start of timeline, playhead,
    /// and the cumulative in/out time of each primary-track segment
    /// accounting for per-segment speedRate. Keeps the audio track
    /// in sync with the visible video chip boundaries — dragging a
    /// voiceover to the start of segment 3 "just works".
    private func buildSnapTargets() -> [Double] {
        var out: [Double] = [0, document.currentTime]
        var cursor: Double = 0
        for t in document.tracks where t.kind == .video {
            for s in t.segments {
                let start = s.placementOffset ?? cursor
                let dur = max(0.1, s.range.endSeconds - s.range.startSeconds) /
                          max(0.1, s.speedRate == 0 ? 1 : s.speedRate)
                out.append(start)
                out.append(start + dur)
                if s.placementOffset == nil { cursor = start + dur }
            }
        }
        return out
    }

    /// Snap `t` to the nearest entry in `snapTargets` if it's within
    /// `snapThresholdPx` on-screen pixels. Returns the snapped time
    /// and whether a snap actually happened (for the highlight).
    private func applySnap(_ t: Double) -> (Double, Bool) {
        let snapThresholdPx: CGFloat = 10
        let thresholdSec = Double(snapThresholdPx / max(pixelsPerSecond, 1))
        var best = t
        var bestDist = Double.infinity
        for target in snapTargets {
            let d = abs(target - t)
            if d < bestDist { bestDist = d; best = target }
        }
        if bestDist <= thresholdSec { return (best, true) }
        return (t, false)
    }

    @ViewBuilder
    private func chip(for seg: TimelineSegment) -> some View {
        let baseStart = seg.range.startSeconds
        let baseEnd = seg.range.endSeconds
        let liveStart = trimming == seg.id ? baseStart + trimLeftDelta : baseStart
        let liveEnd = trimming == seg.id ? baseEnd + trimRightDelta : baseEnd
        let width = max(CGFloat(2), CGFloat(max(0.1, liveEnd - liveStart)) * pixelsPerSecond)
        let sourceDur = document.manifest.media
            .first(where: { $0.id == seg.sourceVideoID })?.analysis?.durationSeconds ?? seg.range.endSeconds
        let baseOffset = seg.placementOffset ?? 0
        // Effective offset = base + drag delta + trim-left delta
        // (left trim pulls the chip's left edge inward relative to
        // the timeline).
        let liveOffset: Double = {
            var o = baseOffset
            if dragging == seg.id { o += dragDeltaSeconds }
            if trimming == seg.id { o += trimLeftDelta }
            return max(0, o)
        }()
        let isSelected = document.selectedSegmentID == seg.id
        ZStack(alignment: .topLeading) {
            WaveformSegmentView(
                envelope: store.envelope(for: seg.sourceVideoID),
                sourceDuration: sourceDur,
                startSeconds: liveStart,
                endSeconds: liveEnd,
                tint: tint
            )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        dragging == seg.id && isSnapped ? Color.white :
                            (isSelected ? Color.white : Color.clear),
                        lineWidth: isSelected ? 1.5 : 1.2
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { document.selectSegment(seg.id) }
            .contextMenu { audioContextMenu(for: seg) }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragging != seg.id {
                            dragging = seg.id
                            snapTargets = buildSnapTargets()
                                .filter { abs($0 - baseOffset) > 0.001 }
                            document.beginInteractiveEdit()
                        }
                        let raw = baseOffset + Double(value.translation.width / pixelsPerSecond)
                        let (snapped, snapHit) = applySnap(max(0, raw))
                        dragDeltaSeconds = snapped - baseOffset
                        // Crisp tick the moment the chip engages a
                        // snap target (rising edge only) so the user
                        // feels the alignment instead of having to
                        // watch the border flash.
                        if snapHit && !isSnapped {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        isSnapped = snapHit
                    }
                    .onEnded { _ in
                        let finalOffset = max(0, baseOffset + dragDeltaSeconds)
                        dragging = nil
                        dragDeltaSeconds = 0
                        isSnapped = false
                        snapTargets = []
                        document.setAudioPlacement(segmentID: seg.id, newOffset: finalOffset)
                        document.endInteractiveEdit()
                    }
            )

            if isSelected && dragging != seg.id {
                audioTrimHandle(for: seg, side: .leading)
                audioTrimHandle(for: seg, side: .trailing)
                    .offset(x: width - 6)
            }
        }
        .offset(x: CGFloat(liveOffset) * pixelsPerSecond)
    }

    private enum TrimSide { case leading, trailing }

    /// Trim handle for audio chips. Leading side adjusts
    /// range.startSeconds (and visual offset); trailing side
    /// adjusts range.endSeconds. Clamp to [0, sourceDuration] with
    /// 0.1s minimum width. Commit via trimAudioSegment on release
    /// so the mutation is a single undo snapshot.
    @ViewBuilder
    private func audioTrimHandle(for seg: TimelineSegment, side: TrimSide) -> some View {
        let sourceDur = document.manifest.media
            .first(where: { $0.id == seg.sourceVideoID })?.analysis?.durationSeconds ?? seg.range.endSeconds
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white)
            .frame(width: 6, height: height + 4)
            .offset(y: -2)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if trimming != seg.id {
                            trimming = seg.id
                            document.beginInteractiveEdit()
                        }
                        let deltaSec = Double(v.translation.width / pixelsPerSecond)
                        switch side {
                        case .leading:
                            let newStart = min(max(seg.range.startSeconds + deltaSec, 0),
                                               seg.range.endSeconds - 0.1)
                            trimLeftDelta = newStart - seg.range.startSeconds
                        case .trailing:
                            let newEnd = min(max(seg.range.endSeconds + deltaSec,
                                                 seg.range.startSeconds + 0.1),
                                             sourceDur)
                            trimRightDelta = newEnd - seg.range.endSeconds
                        }
                    }
                    .onEnded { _ in
                        let newStart = seg.range.startSeconds + trimLeftDelta
                        let newEnd = seg.range.endSeconds + trimRightDelta
                        trimming = nil
                        trimLeftDelta = 0
                        trimRightDelta = 0
                        document.trimAudioSegment(segmentID: seg.id,
                                                  newStart: newStart,
                                                  newEnd: newEnd)
                        document.endInteractiveEdit()
                    }
            )
    }

    /// Minimal context menu for detached-audio chips. Picks up the
    /// verbs that actually make sense on an audio-only segment:
    /// split / delete. Reattach is offered only when the audio has
    /// a `linkedSegmentID` back to its original video. Volume /
    /// fade-in-out live in the EditAdjust sheets once the chip is
    /// selected, so we don't duplicate them here.
    @ViewBuilder
    private func audioContextMenu(for seg: TimelineSegment) -> some View {
        Button {
            document.selectSegment(seg.id)
            document.splitAtPlayhead()
        } label: { Label("在播放头分割", systemImage: "scissors") }

        if seg.linkedSegmentID != nil {
            Button {
                document.selectSegment(seg.id)
                document.reattachSelectedAudio()
            } label: { Label("合并回视频", systemImage: "link") }
        }

        Divider()

        Button(role: .destructive) {
            document.selectSegment(seg.id)
            document.deleteSelectedSegment()
        } label: { Label("删除", systemImage: "trash") }
    }
}

private struct WaveformSegmentView: View {
    let envelope: [Float]?
    let sourceDuration: Double
    let startSeconds: Double
    let endSeconds: Double
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            guard let env = envelope, !env.isEmpty else {
                let path = Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1))
                ctx.fill(path, with: .color(tint.opacity(0.35)))
                return
            }
            let sourceDur = max(sourceDuration, 0.01)
            let startFrac = max(0, min(1, startSeconds / sourceDur))
            let endFrac = max(startFrac, min(1, endSeconds / sourceDur))
            let startIdx = Int(Double(env.count) * startFrac)
            let endIdx = max(startIdx + 1, Int(Double(env.count) * endFrac))
            let slice = Array(env[startIdx..<min(endIdx, env.count)])
            guard !slice.isEmpty else { return }

            let barWidth: CGFloat = 1.5
            let gap: CGFloat = 0.5
            let step = barWidth + gap
            let barsOnScreen = max(1, Int(size.width / step))
            let midY = size.height / 2
            let maxH = size.height - 2

            for i in 0..<barsOnScreen {
                let srcStart = Int(Double(i) * Double(slice.count) / Double(barsOnScreen))
                let srcEnd = max(srcStart + 1,
                                 Int(Double(i + 1) * Double(slice.count) / Double(barsOnScreen)))
                var peak: Float = 0
                for j in srcStart..<min(srcEnd, slice.count) {
                    if slice[j] > peak { peak = slice[j] }
                }
                let scaled = CGFloat(pow(Double(peak), 0.7))
                let h = max(1, scaled * maxH)
                let x = CGFloat(i) * step
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                ctx.fill(Path(rect), with: .color(tint))
            }
        }
        .background(tint.opacity(0.12))
    }
}

// MARK: - Fixed-playhead scroll host

/// UIScrollView-backed horizontal timeline that keeps a fixed center
/// playhead. Scrolling the track left/right updates `currentTime`
/// (seek); when `currentTime` changes from outside (playback), the
/// scroll offset is programmatically synced so the content slides
/// under the stationary playhead — the CapCut behaviour.
///
/// SwiftUI's own `ScrollView` can't expose contentOffset cleanly on
/// iOS 17 (our deployment target) and fights with custom drag
/// gestures, so we wrap UIKit directly. Content is rendered via a
/// `UIHostingController` so all the SwiftUI rows (clips, waveform,
/// subtitle chips) stay intact.
private struct CenteredTimelineScroll<Content: View>: UIViewRepresentable {
    @Binding var currentTime: Double
    var pixelsPerSecond: CGFloat
    var leadingPad: CGFloat
    var trailingPad: CGFloat
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coord { Coord(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceHorizontal = true
        sv.bounces = true
        sv.delegate = context.coordinator
        sv.backgroundColor = .clear
        sv.clipsToBounds = true

        let host = UIHostingController(rootView: AnyView(wrappedContent()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        sv.addSubview(host.view)
        context.coordinator.host = host

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
        ])
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host.rootView = AnyView(wrappedContent())

        // Sync document.currentTime → contentOffset when the user
        // isn't actively dragging. Guarded with a flag so the
        // delegate callback we trigger here doesn't loop back into
        // a seek.
        let targetX = CGFloat(max(0, currentTime)) * pixelsPerSecond
        if !context.coordinator.isUserScrolling,
           abs(sv.contentOffset.x - targetX) > 0.5 {
            context.coordinator.isProgrammatic = true
            sv.setContentOffset(CGPoint(x: targetX, y: sv.contentOffset.y), animated: false)
            DispatchQueue.main.async {
                context.coordinator.isProgrammatic = false
            }
        }
    }

    @ViewBuilder
    private func wrappedContent() -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingPad, height: 1)
            content()
            Color.clear.frame(width: trailingPad, height: 1)
        }
    }

    final class Coord: NSObject, UIScrollViewDelegate {
        var parent: CenteredTimelineScroll
        var host: UIHostingController<AnyView>!
        var isUserScrolling = false
        var isProgrammatic = false

        init(parent: CenteredTimelineScroll) { self.parent = parent }

        func scrollViewWillBeginDragging(_ sv: UIScrollView) { isUserScrolling = true }

        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate dec: Bool) {
            if !dec { isUserScrolling = false }
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) { isUserScrolling = false }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            guard isUserScrolling, !isProgrammatic else { return }
            let t = Double(max(0, sv.contentOffset.x) / parent.pixelsPerSecond)
            parent._currentTime.wrappedValue = t
        }
    }
}

import SwiftUI
import CuttiKit

/// Minimal YouTube-style chapter strip shown over the bottom of the
/// preview canvas while the timeline has authored chapters. Mirrors
/// the macOS `ChapterBarOverlay` visual (segmented bar + active-title
/// label) without porting the live-drag boundary handles — those
/// belong on the macOS-style timeline editor and are tracked
/// separately. Live, not burnt-in: drives off `document.currentTime`
/// via the player's periodic time observer (same one the subtitle
/// overlay listens to).
struct ChapterBarStrip: View {
    @EnvironmentObject var document: ProjectDocument

    var body: some View {
        let chapters = document.chapters
        let total = max(0.001, document.primaryDurationSeconds)
        let active = document.currentChapter

        VStack(alignment: .center, spacing: 4) {
            if let active {
                Text(active.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(chapters) { c in
                        let frac = max(0, c.endSeconds - c.startSeconds) / total
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.25))
                            if active?.id == c.id {
                                let inner = (document.currentTime - c.startSeconds)
                                    / max(0.001, c.endSeconds - c.startSeconds)
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: max(0, geo.size.width * frac * inner))
                            } else if c.endSeconds <= document.currentTime {
                                Capsule()
                                    .fill(Color.white.opacity(0.7))
                            }
                        }
                        .frame(width: max(2, geo.size.width * frac))
                    }
                }
                .frame(height: 4)
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
    }
}

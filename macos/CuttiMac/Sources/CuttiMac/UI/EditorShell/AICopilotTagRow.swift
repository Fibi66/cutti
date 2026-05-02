import SwiftUI

/// A horizontally-scrolling row of semantic tag pills for a media browser row.
/// The view renders nothing when `tags` is empty.
struct AICopilotTagRow: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(EditorShellStyle.accentSolid.opacity(0.15))
                            .foregroundStyle(EditorShellStyle.accentSolid)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

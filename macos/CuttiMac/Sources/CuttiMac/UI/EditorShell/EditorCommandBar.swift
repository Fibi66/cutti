import SwiftUI

struct EditorCommandBar: View {
    let canExport: Bool
    let isExporting: Bool
    let onImport: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Button(action: onImport) {
                Label { T("Import") } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderedProminent)

            Button(action: onExport) {
                Label {
                    T(isExporting ? "Exporting…" : "Export")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!canExport || isExporting)
        }
        .padding(.horizontal, EditorShellStyle.panelPadding)
        .frame(height: EditorShellStyle.commandBarHeight)
        .background(EditorShellStyle.chromeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(EditorShellStyle.subtleBorder)
                .frame(height: 1)
        }
    }
}

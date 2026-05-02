import SwiftUI

/// Single entry point. Routes between iPhone-compact and iPad/regular layouts
/// based on horizontal size class, so iPhone landscape on Max models and
/// iPad Split View both get the regular layout automatically.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let doc = appState.currentDocument {
                if hSize == .compact {
                    EditorPhoneLayout().environmentObject(doc)
                } else {
                    EditorPadLayout().environmentObject(doc)
                }
            } else {
                ProjectDashboardView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hSize)
    }
}

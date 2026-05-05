import SwiftUI

/// Stable identifiers for every page in the Settings sidebar. The shell
/// uses these for selection state and conditional visibility; the
/// sidebar view renders the user-facing labels.
enum SettingsSection: String, Identifiable, Hashable {
    case account
    case provider
    case subscription
    case usage
    case general
    case updates
    case support
    case developer

    var id: String { rawValue }

    /// Localized title shown in the sidebar.
    var title: LocalizedStringKey {
        switch self {
        case .account:      return "Account"
        case .provider:     return "AI Provider"
        case .subscription: return "Subscription"
        case .usage:        return "Credit Usage"
        case .general:      return "General"
        case .updates:      return "Updates"
        case .support:      return "Support"
        case .developer:    return "Developer"
        }
    }

    /// SF Symbol shown on the left of the sidebar row.
    var icon: String {
        switch self {
        case .account:      return "person.crop.circle"
        case .provider:     return "cpu"
        case .subscription: return "creditcard"
        case .usage:        return "chart.bar.xaxis"
        case .general:      return "slider.horizontal.3"
        case .updates:      return "arrow.triangle.2.circlepath"
        case .support:      return "lifepreserver"
        case .developer:    return "hammer"
        }
    }
}

/// Compact dark sidebar pinned at 200pt. Renders the visible-section
/// list returned by the parent shell, owns nothing, and emits selection
/// changes through a binding. The version footer at the bottom comes
/// from `Bundle.main.infoDictionary` (matching what BugReportService
/// already shows).
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let visibleSections: [SettingsSection]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleSections) { section in
                        SidebarRow(
                            section: section,
                            selected: selection == section,
                            tap: { selection = section }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            Divider()
                .overlay(SettingsTheme.borderSoft)

            VStack(alignment: .leading, spacing: 2) {
                Text(versionLine)
                    .font(SettingsTheme.monoBadge)
                    .foregroundStyle(SettingsTheme.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: SettingsTheme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SettingsTheme.panel)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (info?["CFBundleVersion"] as? String) ?? "—"
        return "v\(version) · build \(build)"
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let tap: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.textDim)
                    .frame(width: 18)
                T(section.title)
                    .font(SettingsTheme.ui(12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? SettingsTheme.text : SettingsTheme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                    .fill(selected ? SettingsTheme.panel3 : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                    .strokeBorder(focused ? SettingsTheme.accent.opacity(0.5) : Color.clear,
                                  lineWidth: focused ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
    }
}

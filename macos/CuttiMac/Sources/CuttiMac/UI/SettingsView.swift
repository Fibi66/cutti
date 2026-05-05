import AppKit
import SwiftUI

/// Root of the redesigned Settings window — Obsidian-Pro dark theme,
/// custom HStack sidebar + detail. Hosted by the standard SwiftUI
/// `Settings { }` scene so ⌘, integration is preserved (the system
/// titlebar sits above this content, by design — see notes in plan.md).
///
/// Conditional sections:
/// - Account is always visible.
/// - AI Provider only when signed in.
/// - AI Quality / Subscription / Credit Usage only when signed in AND
///   the user is on Cutti Cloud (BYOK users pay their upstream provider
///   directly, so these would be misleading).
/// - General / Video Editor / Support / Developer always visible.
///
/// Selection lives in `@State` and snaps when the visible-section list
/// shrinks because of a sign-out or provider change. Sign-out → falls
/// back to `account` (the action the user just took), provider switch
/// → `provider` (the place they made the change), other shrinks → first
/// visible (defensive).
struct SettingsView: View {
    @AppStorage(CuttiSettings.aiProviderKey)
    private var aiProviderRaw: String = AIProviderPreference.cuttiCloud.rawValue

    @ObservedObject private var session = RelaySession.shared

    @State private var selection: SettingsSection = .account
    /// Tracks the previous (signed-in, provider) tuple so the
    /// sidebar-fallback `.onChange` can tell what direction the user
    /// just moved in (sign-in → sign-out, cloud → BYOK, etc.).
    @State private var lastSignedIn: Bool = RelaySession.shared.isSignedIn
    @State private var lastProvider: AIProviderPreference = {
        AIProviderPreference(rawValue: UserDefaults.standard.string(forKey: CuttiSettings.aiProviderKey) ?? "")
            ?? .cuttiCloud
    }()

    private var aiProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .cuttiCloud
    }

    private var visibleSections: [SettingsSection] {
        var list: [SettingsSection] = [.account]
        if session.isSignedIn {
            list.append(.provider)
            if aiProvider == .cuttiCloud {
                // Quality lives inside Provider on Cloud, so it isn't a
                // sidebar entry. Subscription / Usage stay separate
                // because they're orthogonal to provider config.
                list.append(contentsOf: [.subscription, .usage])
            }
        }
        list.append(.general)
        // Auto-update controls only exist on direct-download builds.
        // On Mac App Store builds Apple handles updates and Sparkle is
        // not even instantiated (see SparkleUpdater).
        if SparkleUpdater.shared.isEnabled {
            list.append(.updates)
        }
        list.append(contentsOf: [.support, .developer])
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: $selection,
                visibleSections: visibleSections
            )
            Divider()
                .overlay(SettingsTheme.borderSoft)
            ScrollView(.vertical, showsIndicators: true) {
                detail
                    .padding(.horizontal, SettingsTheme.detailPaddingH)
                    .padding(.top, SettingsTheme.detailPaddingV)
                    .padding(.bottom, SettingsTheme.detailPaddingBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(SettingsTheme.bg)
        }
        .frame(width: SettingsTheme.windowWidth, height: SettingsTheme.windowHeight)
        .background(SettingsTheme.bg)
        .preferredColorScheme(.dark)
        .tint(SettingsTheme.accent)
        .onAppear {
            // Defensive: snap selection to the first visible section if
            // the persisted value (none currently, but in case we add
            // it) points at a hidden one.
            if !visibleSections.contains(selection) {
                selection = visibleSections.first ?? .general
            }
            lastSignedIn = session.isSignedIn
            lastProvider = aiProvider
        }
        .onChange(of: session.isSignedIn) { _, nowSignedIn in
            if !nowSignedIn && lastSignedIn {
                // Sign-out: surface the action the user just took.
                selection = .account
            } else if nowSignedIn && !lastSignedIn {
                // Sign-in: stay where they were unless they were on a
                // section that requires sign-in (which they weren't,
                // since it was hidden) — no-op.
            }
            lastSignedIn = nowSignedIn
            // Re-snap if we landed on a now-hidden section.
            if !visibleSections.contains(selection) {
                selection = visibleSections.first ?? .general
            }
        }
        .onChange(of: aiProvider) { _, newProvider in
            if newProvider != lastProvider {
                // Provider switch: surface the section that just
                // changed so the user sees the visible consequences
                // (Quality/Subscription/Usage appearing or disappearing).
                if !visibleSections.contains(selection) {
                    selection = .provider
                }
            }
            lastProvider = newProvider
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .account:      AccountSection()
        case .provider:     ProviderSection()
        case .subscription: SubscriptionSection()
        case .usage:        UsageSection()
        case .general:      GeneralSection()
        case .updates:      UpdatesSection()
        case .support:      SupportSection()
        case .developer:    DeveloperSection()
        }
    }
}

// MARK: - Convenience

extension OpenAIConfiguration {
    /// Historical alias for `fromEnvironment()`. Settings no longer stores
    /// any AI credentials locally — the relay is the only backend — but
    /// this wrapper stays to keep existing call sites compiling.
    @MainActor
    static func fromUserSettings() -> OpenAIConfiguration? {
        fromEnvironment()
    }
}

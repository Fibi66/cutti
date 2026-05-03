import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(CuttiSettings.subtitlesVisibleByDefaultKey) private var subtitlesVisibleByDefault: Bool = true
    @AppStorage(CuttiSettings.editorLanguageKey) private var editorLanguageRaw: String = EditorLanguagePreference.automatic.rawValue
    @AppStorage(CuttiSettings.showAgentTraceKey) private var showAgentTrace: Bool = false
    @AppStorage(CuttiSettings.uiLanguageKey) private var uiLanguage: String = CuttiSettings.uiLanguageSystem
    @AppStorage(CuttiSettings.aiProviderKey) private var aiProviderRaw: String = AIProviderPreference.cuttiCloud.rawValue

    /// Observed so the AI Provider + Subscription sections appear /
    /// disappear automatically as the user signs in or out without
    /// closing and re-opening Settings.
    @ObservedObject private var session = RelaySession.shared

    /// Snapshot of `uiLanguage` taken when this Settings window opens.
    /// The picker writes through to AppStorage immediately (so the value
    /// persists), but we only prompt for restart when the new value
    /// diverges from this baseline.
    @State private var initialUILanguage: String = CuttiSettings.uiLanguageSystem
    @State private var showRestartPrompt: Bool = false
    @State private var showsBugReportSheet: Bool = false

    private var aiProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .cuttiCloud
    }

    private var editorLanguageSelection: Binding<EditorLanguagePreference> {
        Binding(
            get: { EditorLanguagePreference(rawValue: editorLanguageRaw) ?? .automatic },
            set: { editorLanguageRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            // Account is required regardless of provider — both Cutti
            // Cloud and BYOK users need a cutti account to use the app.
            Section {
                AccountSettingsRow()
            } header: {
                T("Account")
            }

            // AI Provider + Subscription only make sense after sign-in.
            // Showing them while signed-out is misleading: BYOK keys
            // would be configurable but unusable, and Subscription
            // shows nothing useful.
            if session.isSignedIn {
                Section {
                    AIProviderSettingsSection()
                } header: {
                    T("AI Provider")
                }

                // Quality / cost picker. Server-authoritative — the open
                // source client only PUTs the choice up; routing happens
                // entirely on the relay.
                if aiProvider == .cuttiCloud {
                    Section {
                        QualityModePickerRow()
                    } header: {
                        T("Quality")
                    }
                }

                // Subscription / credits only matter when AI calls are
                // billed through the relay. Custom (BYOK) users pay
                // their upstream provider directly and the row is
                // misleading there, so we hide it.
                if aiProvider == .cuttiCloud {
                    Section {
                        SubscriptionSettingsRow()
                    } header: {
                        T("Subscription")
                    }

                    Section {
                        UsageBreakdownRow()
                    } header: {
                        T("Credit usage by feature")
                    }
                }
            }

            Section {
                Toggle(isOn: $subtitlesVisibleByDefault) { T("Show subtitles by default") }

                T("New editing sessions start with subtitle overlays visible in the viewer and timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                T("General")
            }

            Section {
                Picker(selection: editorLanguageSelection) {
                    ForEach(EditorLanguagePreference.allCases) { language in
                        T(LocalizedStringKey(language.title)).tag(language)
                    }
                } label: {
                    T("Speech language")
                }

                T("Choose the main spoken language in your clip. Cutti will handle speech recognition automatically in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(selection: $uiLanguage) {
                    T("System").tag(CuttiSettings.uiLanguageSystem)
                    T("English").tag(CuttiSettings.uiLanguageEnglish)
                    T("Chinese").tag(CuttiSettings.uiLanguageChinese)
                } label: {
                    T("Interface language")
                }
                .onChange(of: uiLanguage) { _, newValue in
                    if newValue != initialUILanguage {
                        showRestartPrompt = true
                    }
                }

                T("Choose the language used throughout Cutti's interface. Independent from the speech-recognition language above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                T("Video Editor")
            }

            Section {
                Button {
                    showsBugReportSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug")
                        T("Report a Bug…")
                    }
                }

                T("Send us a description of what went wrong. Optionally attaches app and OS version, hardware, and locale so we can reproduce the issue. Goes straight to GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                T("Support")
            }

            Section {
                Toggle(isOn: $showAgentTrace) { T("Show agent trace") }

                T("Reveals the raw agent trace inspector in the AI Editor header, with per-turn step lists, Undo Entire Plan, and Copy Trace JSON. Off by default — everyday users only need the plain-language action bubbles in the chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                T("Developer")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 540)
        .onAppear { initialUILanguage = uiLanguage }
        .sheet(isPresented: $showsBugReportSheet) {
            BugReportSheet()
        }
        .alert(L("Restart Required"), isPresented: $showRestartPrompt) {
            Button(role: .cancel) {
                // Revert the picker so the visible state matches what's
                // actually loaded; user can retry when ready to restart.
                uiLanguage = initialUILanguage
            } label: {
                T("Cancel")
            }
            Button {
                relaunchApp()
            } label: {
                T("Apply & Restart")
            }
        } message: {
            T("Changing the interface language requires restarting Cutti. Your project and unsaved edits will be preserved.")
        }
    }

    /// Launches a fresh instance of Cutti and quits this one.
    ///
    /// In production (signed `.app` bundle) we use `/usr/bin/open -n`
    /// which correctly registers a second instance with launchd. When
    /// running via `swift run` during development, `Bundle.main` is
    /// the raw executable inside `.build/`, which `open -n` refuses
    /// — so we just `Process.run()` the executable directly.
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"

        let task = Process()
        if isAppBundle {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else if let executableURL = Bundle.main.executableURL {
            task.executableURL = executableURL
        } else {
            // Last-ditch: terminate without relaunch. User restarts
            // manually but the language pref is already persisted.
            NSApp.terminate(nil)
            return
        }

        do {
            try task.run()
        } catch {
            print("Failed to relaunch cutti: \(error)")
        }
        NSApp.terminate(nil)
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

// MARK: - Subscription row

/// Inline subscription surface living in the Settings root page. Shows a
/// single "Subscribe" button that either opens the web landing page
/// (direct-download builds) or presents the native StoreKit subscription
/// sheet (Mac App Store builds), plus the credits progress bar when
/// Subscription / credit / upgrade row for the Settings window.
///
/// **Only shown when AI provider is `cuttiCloud`** — for BYOK users
/// the upstream provider does the billing, so this row would be
/// confusing. Account / sign-in is handled separately by
/// `AccountSettingsRow`, which is shown for *both* modes.
private struct SubscriptionSettingsRow: View {
    @ObservedObject private var session = RelaySession.shared
    @State private var showStoreKitSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    planTitle.font(.headline)
                    statusSubtitle.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if session.isSignedIn {
                signedInContent
            }

            if let err = session.lastError {
                Text(err).font(.caption).foregroundStyle(EditorShellStyle.destructiveSolid)
            }
        }
        .task { if session.isSignedIn { await session.refreshMe() } }
        .sheet(isPresented: $showStoreKitSheet) {
            StoreKitSubscriptionSheet(dismiss: { showStoreKitSheet = false })
        }
    }

    // MARK: - Signed-in view

    @ViewBuilder
    private var signedInContent: some View {
        if let credits = session.credits {
            VStack(alignment: .leading, spacing: 10) {
                // Monthly subscription bucket
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: credits.percentUsed)
                        .progressViewStyle(.linear)
                        .tint(creditsTint(percent: credits.percentUsed))
                        .frame(maxWidth: .infinity)
                    HStack {
                        Text(String(format: L("%@ monthly credits left"), credits.remaining.formatted()))
                            .font(.caption)
                            .monospacedDigit()
                        Spacer()
                        Text(String(format: L("of %@"), credits.quota.formatted()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Pack bucket (never-expires, purchased separately) — no progress bar,
                // pack credits are pure balance: you spend them, what's left is left.
                HStack(spacing: 6) {
                    Image(systemName: "bag.fill")
                        .font(.caption2)
                        .foregroundStyle(credits.balancePack > 0 ? .purple : Color.secondary)
                    Text(String(format: L("%@ pack credits left"), credits.balancePack.formatted()))
                        .font(.caption)
                        .monospacedDigit()
                    T("· never expire")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Button {
            handleSubscribeTap()
        } label: {
            Text(session.subscription?.status == "active" ? "Manage Subscription" : "Subscribe")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func handleSubscribeTap() {
        switch CuttiDistribution.current {
        case .appStore:
            showStoreKitSheet = true
        case .direct:
            NSWorkspace.shared.open(CuttiDistribution.landingURL)
        }
    }

    private func creditsTint(percent: Double) -> Color {
        switch percent {
        case ..<0.75: return .accentColor
        case 0.75..<0.95: return .orange
        default: return .red
        }
    }

    private var planTitle: Text {
        if !session.isSignedIn {
            return T("Not signed in")
        }
        if let plan = session.subscription?.plan, !plan.isEmpty {
            // Plan name from server — not localized.
            return Text(plan.capitalized + " plan")
        }
        return T("Free plan")
    }

    private var statusSubtitle: Text {
        if !session.isSignedIn {
            return T("Sign in to view your plan.")
        }
        if let sub = session.subscription {
            // Status comes from the relay — server-controlled string.
            var parts: [String] = [sub.status.capitalized]
            if let r = sub.renewalAt {
                parts.append("renews \(Date(timeIntervalSince1970: TimeInterval(r)).formatted(date: .abbreviated, time: .omitted))")
            }
            return Text(parts.joined(separator: " · "))
        }
        return Text("—")
    }
}

/// In-app sign-in sheet. Sign-up happens on the website
/// (`CuttiDistribution.signupURL`); only returning users see this form.
struct AuthSheet: View {
    let dismiss: () -> Void

    @ObservedObject private var session = RelaySession.shared
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isBusy: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Email"), text: $email)
                        .textContentType(.emailAddress)
                        .disableAutocorrection(true)
                    SecureField(L("Password"), text: $password)
                        .textContentType(.password)
                }

                if let err = errorMessage {
                    Section { Text(err).font(.caption).foregroundStyle(EditorShellStyle.destructiveSolid) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isBusy { ProgressView().controlSize(.small) }
                            else { T("Sign In").bold() }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }

                Section {
                    Button {
                        NSWorkspace.shared.open(CuttiDistribution.signupURL)
                    } label: { T("Don't have an account? Create one →") }
                    .buttonStyle(.link)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
            .navigationTitle(L("Sign In"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismiss) { T("Cancel") }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 320)
    }

    private var canSubmit: Bool {
        !isBusy && email.contains("@") && !password.isEmpty
    }

    private func submit() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            try await session.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password)
            dismiss()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        if raw.contains("invalid_credentials") { return "Email or password is incorrect." }
        if raw.contains("invalid_email") { return "Please enter a valid email address." }
        if raw.contains("invalid_request") { return "Email and password are required." }
        return raw
    }
}

/// Thin StoreKit presentation sheet used on Mac App Store builds. Shows
/// the available subscription products with their prices so the user can
/// tap one to subscribe. (SubscriptionStoreView is macOS 15+, and we ship
/// macOS 14 — so this is a lightweight equivalent.)
private struct StoreKitSubscriptionSheet: View {
    let dismiss: () -> Void
    @ObservedObject private var store = SubscriptionManager.shared

    var body: some View {
        NavigationStack {
            Form {
                if store.isLoading && store.products.isEmpty {
                    ProgressView()
                } else if store.products.isEmpty {
                    T("Subscription products are not available on this build yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.products, id: \.id) { product in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(product.displayName).font(.headline)
                                Text(product.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(product.displayPrice).monospacedDigit()
                            Button {
                                Task { await store.purchase(product) }
                            } label: { T("Subscribe") }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Button {
                    Task { await store.restorePurchases() }
                } label: { T("Restore Purchases") }
                .buttonStyle(.bordered)
                if let err = store.lastError {
                    Text(err).font(.caption).foregroundStyle(EditorShellStyle.destructiveSolid)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Subscribe"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: dismiss) { T("Done") }
                }
            }
            .task { await store.loadProducts() }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

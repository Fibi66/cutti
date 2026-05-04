import AppKit
import SwiftUI

/// Sign-in modal sheet for the redesigned Settings. Same email + password
/// flow as the legacy `AuthSheet`, restyled with the dark Obsidian-Pro
/// chrome. Sign-up still happens on the website.
///
/// Renamed from `AuthSheet` to `SettingsAuthSheet` to coexist with the
/// legacy file during the redesign migration; once that file is removed
/// this can be renamed back if desired.
struct SettingsAuthSheet: View {
    let dismiss: () -> Void

    @ObservedObject private var session = RelaySession.shared
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isBusy: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                T("Sign in")
                    .font(SettingsTheme.ui(15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.text)
                T("Use your Cutti account to enable AI features.")
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Form
            VStack(spacing: 10) {
                fieldGroup(label: "Email") {
                    SettingsField(
                        text: $email,
                        placeholder: "name@example.com",
                        mono: false,
                        maxWidth: nil
                    )
                }
                fieldGroup(label: "Password") {
                    SettingsField(
                        text: $password,
                        placeholder: "••••••••",
                        secure: true,
                        maxWidth: nil
                    )
                }

                if let err = errorMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.red)
                        Text(err)
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            // Footer with secondary link + actions
            VStack(spacing: 0) {
                Rectangle()
                    .fill(SettingsTheme.borderSoft)
                    .frame(height: 1)
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(CuttiDistribution.signupURL)
                    } label: {
                        T("Don't have an account? Create one →")
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    SettingsButton(
                        "Cancel",
                        variant: .ghost,
                        size: .medium,
                        action: dismiss
                    )
                    SettingsButton(
                        variant: .primary,
                        size: .medium,
                        loading: isBusy,
                        disabled: !canSubmit,
                        action: { Task { await submit() } },
                        label: { T("Sign in") }
                    )
                    .keyboardShortcut(.return, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(SettingsTheme.panel2)
            }
        }
        .frame(width: 440)
        .background(SettingsTheme.bg)
        .settingsThemed()
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            T(label)
                .font(SettingsTheme.captionFaint)
                .foregroundStyle(SettingsTheme.textDim)
            content()
        }
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
                password: password
            )
            dismiss()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        if raw.contains("invalid_credentials") { return L("Email or password is incorrect.") }
        if raw.contains("invalid_email") { return L("Please enter a valid email address.") }
        if raw.contains("invalid_request") { return L("Email and password are required.") }
        return raw
    }
}

import AppKit
import SwiftUI

/// Account page — three states: signed-out / verified / unverified.
/// Replaces the legacy `AccountSettingsRow` view (the old file is
/// removed in this redesign).
///
/// Logged-out users get the primary Sign-in CTA + a link out to the
/// sign-up web flow (no in-app sign-up form by design — keeps email
/// validation + ToS acceptance on the website). Verified users get a
/// compact identity card. Unverified users see a verification banner
/// with a Resend button.
struct AccountSection: View {
    @ObservedObject private var session = RelaySession.shared

    @State private var showAuthSheet: Bool = false
    @State private var isResendingVerification: Bool = false
    @State private var verificationResendMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Account",
                sub: "Sign in to use AI features. Required for both Cutti Cloud and Custom (BYOK) modes."
            )

            if !session.isSignedIn {
                signedOutCard
            } else if needsEmailVerification {
                identityCard
                verificationBanner.padding(.top, 12)
            } else {
                identityCard
            }

            if let err = session.lastError, !err.isEmpty {
                Text(err)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.red)
                    .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .task { if session.isSignedIn { await session.refreshMe() } }
        .sheet(isPresented: $showAuthSheet) {
            SettingsAuthSheet(dismiss: { showAuthSheet = false })
        }
    }

    // MARK: - Logged out

    @ViewBuilder
    private var signedOutCard: some View {
        SettingsCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    avatarPlaceholder
                    VStack(alignment: .leading, spacing: 2) {
                        T("Not signed in")
                            .font(SettingsTheme.bodyMedium)
                            .foregroundStyle(SettingsTheme.text)
                        T("AI features need an account.")
                            .font(SettingsTheme.captionFaint)
                            .foregroundStyle(SettingsTheme.textDim)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    SettingsButton(
                        "Sign in",
                        variant: .primary,
                        size: .medium
                    ) {
                        showAuthSheet = true
                    }
                    SettingsButton(
                        "Create account",
                        variant: .secondary,
                        size: .medium
                    ) {
                        NSWorkspace.shared.open(CuttiDistribution.signupURL)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var identityCard: some View {
        SettingsCard(padding: 16) {
            HStack(spacing: 12) {
                avatarSigned
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.user?.email ?? L("Signed in"))
                            .font(SettingsTheme.bodyMedium)
                            .foregroundStyle(SettingsTheme.text)
                        if needsEmailVerification {
                            SettingsStatusDot(tone: .amber, label: "Email unverified")
                        } else {
                            SettingsStatusDot(tone: .green, label: "Verified")
                        }
                    }
                    if let id = session.user?.id, !id.isEmpty {
                        Text(id)
                            .font(SettingsTheme.monoSmall)
                            .foregroundStyle(SettingsTheme.textFaint)
                    }
                }
                Spacer(minLength: 0)
                SettingsButton(
                    "Sign out",
                    variant: .secondary,
                    size: .medium
                ) {
                    session.signOut()
                }
            }
        }
    }

    // MARK: - Verification banner

    @ViewBuilder
    private var verificationBanner: some View {
        SettingsCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsTheme.amber)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    T("Verify your email")
                        .font(SettingsTheme.bodyMedium)
                        .foregroundStyle(SettingsTheme.text)
                    Text(verificationMessage)
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SettingsButton(
                            variant: .secondary,
                            size: .small,
                            loading: isResendingVerification,
                            action: { Task { await resendVerification() } },
                            label: { T("Resend email") }
                        )
                        if let msg = verificationResendMessage {
                            Text(msg)
                                .font(SettingsTheme.caption)
                                .foregroundStyle(msg.hasPrefix("✅") ? SettingsTheme.green : SettingsTheme.red)
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var verificationMessage: String {
        if let email = session.user?.email, !email.isEmpty {
            return L("verify.email.message_with_address", email)
        }
        return L("verify.email.message_generic")
    }

    @MainActor
    private func resendVerification() async {
        isResendingVerification = true
        defer { isResendingVerification = false }
        verificationResendMessage = nil
        do {
            try await session.resendVerification()
            verificationResendMessage = "✅ " + L("verify.email.sent")
        } catch {
            let raw = (error as NSError).localizedDescription
            if raw.contains("rate_limited") {
                verificationResendMessage = L("verify.email.rate_limited")
            } else if raw.contains("already_verified") {
                verificationResendMessage = "✅ " + L("verify.email.already_verified")
                await session.refreshMe()
            } else {
                verificationResendMessage = "❌ " + raw
            }
        }
    }

    // MARK: - Avatars

    /// Round 38pt avatar with the first letter of the email, drawn over
    /// the brand gradient. Used for the signed-in state.
    private var avatarSigned: some View {
        let initial = (session.user?.email?.first.map { String($0) } ?? "C").uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [SettingsTheme.accent, SettingsTheme.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initial)
                .font(SettingsTheme.mono(14, weight: .bold))
                .foregroundStyle(Color(.sRGB, red: 0.04, green: 0.04, blue: 0.05, opacity: 1))
        }
        .frame(width: 38, height: 38)
    }

    /// Empty avatar tile shown when signed out — same size + radius so
    /// the row height doesn't jump after sign-in.
    private var avatarPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.panel3)
            Image(systemName: "person.fill")
                .font(.system(size: 14))
                .foregroundStyle(SettingsTheme.textFaint)
        }
        .frame(width: 38, height: 38)
    }

    // MARK: - State helpers

    private var needsEmailVerification: Bool {
        guard let user = session.user else { return false }
        return user.source == "email" && user.emailVerified != true
    }
}

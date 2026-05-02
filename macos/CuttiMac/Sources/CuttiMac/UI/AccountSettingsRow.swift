import AppKit
import SwiftUI

/// Account row for the Settings window. Shown to *both* Cutti Cloud
/// and BYOK users — login is required regardless of which AI backend
/// the user picks (the cutti account anchors per-user state, syncing,
/// and any future cloud-side features even if the user pays their
/// upstream provider directly for AI calls).
///
/// Renders three states:
/// 1. Signed out → Sign In + Create Account buttons.
/// 2. Signed in, email unverified → user email + verification banner
///    + sign-out button.
/// 3. Signed in & verified → user email + sign-out button.
///
/// `SubscriptionSettingsRow` (in SettingsView.swift) shows credit /
/// upgrade UI on top of this — but that row is hidden in BYOK mode.
struct AccountSettingsRow: View {
    @ObservedObject private var session = RelaySession.shared
    @State private var showAuthSheet: Bool = false
    @State private var isResendingVerification: Bool = false
    @State private var verificationResendMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    headerTitle.font(.headline)
                    headerSubtitle.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isSignedIn {
                    Button(role: .destructive) { session.signOut() } label: { T("Sign Out") }
                        .buttonStyle(.bordered)
                }
            }

            if !session.isSignedIn {
                signedOutContent
            } else if needsEmailVerification {
                emailVerificationBanner
            }

            if let err = session.lastError {
                Text(err).font(.caption).foregroundStyle(EditorShellStyle.destructiveSolid)
            }
        }
        .task { if session.isSignedIn { await session.refreshMe() } }
        .sheet(isPresented: $showAuthSheet) {
            AuthSheet(dismiss: { showAuthSheet = false })
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOutContent: some View {
        HStack(spacing: 8) {
            Button {
                showAuthSheet = true
            } label: {
                T("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                NSWorkspace.shared.open(CuttiDistribution.signupURL)
            } label: {
                T("Create Account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Email verification banner

    private var needsEmailVerification: Bool {
        guard let user = session.user else { return false }
        return user.source == "email" && user.emailVerified != true
    }

    @ViewBuilder
    private var emailVerificationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "envelope.badge.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    T("Verify your email")
                        .font(.subheadline).bold()
                    Text(verificationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button {
                    Task { await resendVerification() }
                } label: {
                    if isResendingVerification {
                        ProgressView().controlSize(.small)
                    } else {
                        T("Resend email")
                    }
                }
                .disabled(isResendingVerification)
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let msg = verificationResendMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.hasPrefix("✅") ? .green : .red)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var verificationMessage: String {
        if let email = session.user?.email, !email.isEmpty {
            return "We sent a link to \(email). Click it to unlock AI features. Check spam if you can't find it."
        }
        return "Click the link we sent to your inbox to unlock AI features."
    }

    @MainActor
    private func resendVerification() async {
        isResendingVerification = true
        defer { isResendingVerification = false }
        verificationResendMessage = nil
        do {
            try await session.resendVerification()
            verificationResendMessage = "✅ Sent. Check your inbox."
        } catch {
            let raw = (error as NSError).localizedDescription
            if raw.contains("rate_limited") {
                verificationResendMessage = "Please wait a minute before trying again."
            } else if raw.contains("already_verified") {
                verificationResendMessage = "✅ Already verified — refreshing."
                await session.refreshMe()
            } else {
                verificationResendMessage = "❌ \(raw)"
            }
        }
    }

    // MARK: - Headers

    private var headerTitle: Text {
        if session.isSignedIn {
            // Email is user data, not a translatable string.
            return Text(session.user?.email ?? NSLocalizedString("Signed in", comment: ""))
        }
        return T("Not signed in")
    }

    private var headerSubtitle: Text {
        if !session.isSignedIn {
            return T("Sign in to use AI features.")
        }
        if needsEmailVerification {
            return T("Email verification pending.")
        }
        // Internal user id — never translated.
        return Text(session.user?.id ?? "")
    }
}

import AppKit
import SwiftUI

/// Modal sheet for filing a bug report from inside the app. Reachable
/// from Settings → Support. Restyled for the Obsidian-Pro dark theme:
/// custom titlebar with Cancel/Send buttons, dark cards for each field.
///
/// The disclosure under "Include diagnostics" displays the exact JSON
/// that will be transmitted, so users can verify nothing surprising
/// goes out before they hit Send.
struct BugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = RelaySession.shared

    @State private var description: String = ""
    @State private var reproSteps: String = ""
    @State private var contactEmail: String = ""
    @State private var includeDiagnostics: Bool = true
    @State private var showsDiagnosticsPreview: Bool = false

    @State private var isSubmitting: Bool = false
    @State private var submissionError: String?
    @State private var submissionResponse: BugReportSubmissionResponse?

    /// Diagnostics snapshot taken once when the sheet appears (and
    /// refreshed when the user toggles `Include diagnostics`). Caching
    /// here keeps `submittedAt` stable while the user is typing — the
    /// JSON preview below shouldn't tick every keystroke — and avoids
    /// re-running `sysctlbyname` and `Bundle.main` reads per render.
    @State private var diagnosticsSnapshot: BugReportDiagnostics =
        BugReportDiagnostics.current()

    private var canSubmit: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 10 && !isSubmitting
    }

    private var report: BugReport {
        BugReport(
            description: description,
            reproSteps: reproSteps,
            contactEmail: contactEmail,
            diagnostics: includeDiagnostics ? diagnosticsSnapshot : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(SettingsTheme.borderSoft)
                .frame(height: 1)
            content
            Rectangle()
                .fill(SettingsTheme.borderSoft)
                .frame(height: 1)
            footer
        }
        .frame(width: 560, height: 620)
        .background(SettingsTheme.bg)
        .preferredColorScheme(.dark)
        .tint(SettingsTheme.accent)
        .settingsThemed()
        .onAppear {
            if contactEmail.isEmpty, let email = session.user?.email {
                contactEmail = email
            }
            diagnosticsSnapshot = BugReportDiagnostics.current()
        }
        .onChange(of: includeDiagnostics) { _, newValue in
            if newValue {
                diagnosticsSnapshot = BugReportDiagnostics.current()
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                T("Report a Bug")
                    .font(SettingsTheme.ui(15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.text)
                T("Include enough detail and we'll triage quickly.")
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.textDim)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(SettingsTheme.bg)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            SettingsButton(
                submissionResponse == nil ? "Cancel" : "Close",
                variant: .ghost,
                size: .medium
            ) { dismiss() }

            if submissionResponse == nil {
                SettingsButton(
                    variant: .primary,
                    size: .medium,
                    loading: isSubmitting,
                    disabled: !canSubmit,
                    action: { Task { await submit() } },
                    label: { T("Send") }
                )
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(SettingsTheme.panel2)
    }

    @ViewBuilder
    private var content: some View {
        if let response = submissionResponse {
            successView(response)
        } else {
            ScrollView {
                formContent
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
    }

    // MARK: - Form

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(
                title: "What happened?",
                hint: "Tell us what went wrong. The more detail you can give, the faster we can fix it."
            ) {
                editor(
                    text: $description,
                    minHeight: 110,
                    placeholder: L("e.g. The app froze when I dragged a 4K clip onto an empty timeline.")
                )
            }

            field(title: "Steps to reproduce (optional)") {
                editor(text: $reproSteps, minHeight: 70, placeholder: nil)
            }

            field(
                title: "Reply email (optional)",
                hint: "Only used to follow up on this report. Leave blank to submit anonymously."
            ) {
                SettingsField(
                    text: $contactEmail,
                    placeholder: "name@example.com",
                    mono: false,
                    maxWidth: nil
                )
            }

            field(title: "Privacy") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsToggle(
                        isOn: $includeDiagnostics,
                        label: "Include diagnostics"
                    )
                    T("Helps us reproduce the bug. Includes app and OS version, hardware, locale, and timezone. Does not include your email, account, or project files.")
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup(isExpanded: $showsDiagnosticsPreview) {
                        ScrollView {
                            Text(BugReportService.previewJSON(for: report))
                                .font(SettingsTheme.monoSmall)
                                .foregroundStyle(SettingsTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(height: 160)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(SettingsTheme.panel3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(SettingsTheme.borderSoft, lineWidth: 1)
                        )
                        .padding(.top, 4)
                    } label: {
                        T("Show what will be sent")
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                    }
                    .tint(SettingsTheme.accent)
                }
            }

            if let submissionError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.red)
                    Text(submissionError)
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            T(title)
                .font(SettingsTheme.captionFaint)
                .foregroundStyle(SettingsTheme.textDim)
            SettingsCard(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if let hint {
                        T(hint)
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private func editor(text: Binding<String>, minHeight: CGFloat, placeholder: String?) -> some View {
        TextEditor(text: text)
            .font(SettingsTheme.bodyRegular)
            .foregroundStyle(SettingsTheme.text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SettingsTheme.panel3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsTheme.borderSoft, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if let placeholder, text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(SettingsTheme.bodyRegular)
                        .foregroundStyle(SettingsTheme.textFaint)
                        .padding(.top, 14)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Success

    @ViewBuilder
    private func successView(_ response: BugReportSubmissionResponse) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(SettingsTheme.green)
            T("Thanks — your report is in.")
                .font(SettingsTheme.ui(17, weight: .semibold))
                .foregroundStyle(SettingsTheme.text)
            T("We'll triage it and follow up if we need more info.")
                .font(SettingsTheme.bodyRegular)
                .foregroundStyle(SettingsTheme.textDim)
                .multilineTextAlignment(.center)

            if let issueURLString = response.issueURL,
               let issueURL = Self.safeIssueURL(issueURLString) {
                Button {
                    NSWorkspace.shared.open(issueURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        T("View on GitHub")
                    }
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if let ticketID = response.ticketID {
                Text(verbatim: "Ticket: \(ticketID)")
                    .font(SettingsTheme.monoSmall)
                    .foregroundStyle(SettingsTheme.textFaint)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Submission

    @MainActor
    private func submit() async {
        submissionError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let response = try await BugReportService.shared.submit(report)
            submissionResponse = response
        } catch let error as BugReportError {
            submissionError = error.errorDescription
        } catch {
            submissionError = error.localizedDescription
        }
    }

    /// Only open `issueURL` values that are https GitHub URLs. The
    /// relay is trusted, but a stricter guard protects users if a
    /// future relay misconfiguration (or a man-in-the-middle on a
    /// hostile network) ever returns a non-GitHub or custom-scheme
    /// URL. We don't want to launch arbitrary apps from a success
    /// view.
    private static func safeIssueURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }
        return url
    }
}

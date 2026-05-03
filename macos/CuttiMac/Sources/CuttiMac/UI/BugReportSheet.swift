import AppKit
import SwiftUI

/// Modal sheet for filing a bug report from inside the app. Reachable
/// from Settings → Support. Shows a form, posts the report to the
/// relay (`BugReportService`), and renders a success or failure
/// state inline so the user gets immediate confirmation.
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

    private var canSubmit: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 10 && !isSubmitting
    }

    private var report: BugReport {
        BugReport(
            description: description,
            reproSteps: reproSteps,
            contactEmail: contactEmail,
            diagnostics: includeDiagnostics ? BugReportDiagnostics.current() : nil
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let response = submissionResponse {
                    successView(response)
                } else {
                    formView
                }
            }
            .navigationTitle(L("Report a Bug"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        T(submissionResponse == nil ? "Cancel" : "Close")
                    }
                }
                if submissionResponse == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submit() }
                        } label: {
                            if isSubmitting {
                                ProgressView().controlSize(.small)
                            } else {
                                T("Send")
                            }
                        }
                        .disabled(!canSubmit)
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
        }
        .frame(width: 560, height: 620)
        .onAppear {
            if contactEmail.isEmpty, let email = session.user?.email {
                contactEmail = email
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                T("Tell us what went wrong. The more detail you can give, the faster we can fix it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if description.isEmpty {
                            T("e.g. The app froze when I dragged a 4K clip onto an empty timeline.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                T("What happened?")
            }

            Section {
                TextEditor(text: $reproSteps)
                    .font(.body)
                    .frame(minHeight: 70)
            } header: {
                T("Steps to reproduce (optional)")
            }

            Section {
                TextField(L("name@example.com"), text: $contactEmail)
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)
                T("Only used to follow up on this report. Leave blank to submit anonymously.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                T("Reply email (optional)")
            }

            Section {
                Toggle(isOn: $includeDiagnostics) {
                    T("Include diagnostics")
                }
                T("Helps us reproduce the bug. Includes app and OS version, hardware, locale, and your account ID. Does not include your email or project files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showsDiagnosticsPreview) {
                    ScrollView {
                        Text(BugReportService.previewJSON(for: report))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                } label: {
                    T("Show what will be sent")
                        .font(.caption)
                }
            } header: {
                T("Privacy")
            }

            if let submissionError {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(submissionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Success

    @ViewBuilder
    private func successView(_ response: BugReportSubmissionResponse) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            T("Thanks — your report is in.")
                .font(.title2)
                .fontWeight(.semibold)
            T("We'll triage it and follow up if we need more info.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let issueURLString = response.issueURL,
               let issueURL = URL(string: issueURLString) {
                Button {
                    NSWorkspace.shared.open(issueURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        T("View on GitHub")
                    }
                }
                .buttonStyle(.link)
            }

            if let ticketID = response.ticketID {
                Text(verbatim: "Ticket: \(ticketID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(.top, 60)
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
}

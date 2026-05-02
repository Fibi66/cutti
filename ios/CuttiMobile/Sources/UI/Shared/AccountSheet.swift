import SwiftUI

// Sign-in / account sheet for the iOS app. Reuses the cloud types
// (RelaySession, RelayClient) that are compiled into the iOS target
// from macos/CuttiMac/Sources/CuttiMac/Core/Cloud/.
//
// Flow:
//   - When signed out: email/password form with Sign in / Sign up toggle.
//   - When signed in: shows email, plan, credits, and a Sign out button.
//
// The RelaySession base URL is configured via UserDefaults using the same
// keys the macOS app uses (see RelayClient.Defaults); we set a sane
// production default on first launch in CuttiMobileApp.

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = RelaySession.shared

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var mode: Mode = .signIn
    @State private var isSubmitting = false
    @State private var submitError: String?

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case signUp = "Sign up"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isSignedIn {
                    signedInView
                } else {
                    signInForm
                }
            }
            .navigationTitle(session.isSignedIn ? "Account" : mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signInForm: some View {
        Form {
            Section {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
            }

            if let err = submitError {
                Section {
                    Text(L(err)).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting { ProgressView().padding(.trailing, 4) }
                        Text(mode.rawValue).bold()
                        Spacer()
                    }
                }
                .disabled(isSubmitting || email.isEmpty || password.isEmpty)
            }

            Section {
                Text("Signing in links this device to your Cutti account. Your subscription and credits sync across devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() async {
        submitError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            switch mode {
            case .signIn:
                try await session.signIn(email: email, password: password)
            case .signUp:
                try await session.signUp(email: email, password: password)
            }
        } catch {
            submitError = (error as NSError).localizedDescription
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedInView: some View {
        List {
            Section("Account") {
                LabeledContent("Email", value: session.user?.email ?? "—")
                LabeledContent("Source", value: (session.user?.source ?? "—").capitalized)
            }

            if let sub = session.subscription {
                Section("Subscription") {
                    LabeledContent("Plan", value: sub.plan.capitalized)
                    LabeledContent("Status", value: sub.status.capitalized)
                    if let ts = sub.renewalAt {
                        LabeledContent(
                            "Renews",
                            value: Date(timeIntervalSince1970: TimeInterval(ts))
                                .formatted(date: .abbreviated, time: .omitted),
                        )
                    }
                }
            }

            if let c = session.credits {
                Section("Credits this period") {
                    LabeledContent("Used", value: "\(c.used) / \(c.quota)")
                    LabeledContent("Remaining", value: "\(c.remaining)")
                    ProgressView(value: c.percentUsed)
                }
            }

            if let err = session.lastError {
                Section {
                    Text(L(err)).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Button("Sign out", role: .destructive) {
                    session.signOut()
                }
            }
        }
    }
}

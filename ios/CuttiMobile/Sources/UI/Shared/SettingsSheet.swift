import SwiftUI
import CuttiKit

/// Unified Settings sheet — iOS counterpart to the macOS Settings
/// window. Surfaces the same preference surface the desktop app
/// exposes (Account/Subscription, General, Video Editor speech
/// language, Interface language, Developer, About) so the two
/// platforms stay at parity.
///
/// Uses the same AppStorage keys as macOS (`cutti.*`) so when a
/// user has Cutti on both platforms and syncs iCloud Key-Value Store
/// in the future, preferences map 1:1.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = RelaySession.shared

    @AppStorage("cutti.subtitlesVisibleByDefault") private var subtitlesVisibleByDefault: Bool = true
    @AppStorage("cutti.editorLanguage") private var editorLanguageRaw: String = "automatic"
    @AppStorage("cutti.showAgentTrace") private var showAgentTrace: Bool = false
    @AppStorage("cutti.uiLanguage") private var uiLanguage: String = "system"

    @State private var initialUILanguage: String = "system"
    @State private var showRestartPrompt: Bool = false

    /// When non-nil, presents the sign-in/subscription flow on top of
    /// the settings form. Stays on iOS's native sheet presentation
    /// detent so the user can dismiss and land back in Settings.
    @State private var authSheet: AuthDestination? = nil

    enum AuthDestination: Identifiable {
        case signIn, signUp
        var id: String {
            switch self { case .signIn: return "in"; case .signUp: return "up" }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                if session.isSignedIn {
                    subscriptionSection
                }
                generalSection
                speechSection
                interfaceSection
                developerSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $authSheet) { dest in
                AccountAuthSheet(initialMode: dest == .signUp ? .signUp : .signIn)
                    .presentationDetents([.medium, .large])
            }
            .alert("需要重启", isPresented: $showRestartPrompt) {
                Button("取消", role: .cancel) {
                    uiLanguage = initialUILanguage
                }
                Button("稍后手动重启") {
                    initialUILanguage = uiLanguage
                }
            } message: {
                Text("切换界面语言需要重新打开 Cutti。新设置会在下次启动时生效。")
            }
            .onAppear {
                initialUILanguage = uiLanguage
                Task { await session.refreshMe() }
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if session.isSignedIn {
                if let email = session.user?.email {
                    LabeledContent("邮箱", value: email)
                }
                if let source = session.user?.source {
                    LabeledContent("登录方式", value: source.capitalized)
                }
                Button("退出登录", role: .destructive) {
                    session.signOut()
                }
            } else {
                Button {
                    authSheet = .signIn
                } label: {
                    HStack {
                        Label("登录 Cutti 账号", systemImage: "person.crop.circle.badge.plus")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("还没有账号？前往注册") {
                    authSheet = .signUp
                }
                .font(.footnote)
            }
        } header: {
            Text("账号")
        } footer: {
            if !session.isSignedIn {
                Text("登录后即可使用云端 AI 功能（智能剪辑、视频摘要、章节建议等），订阅和额度在所有设备间同步。")
            }
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Section("订阅") {
            if let sub = session.subscription {
                LabeledContent("计划", value: sub.plan.capitalized)
                LabeledContent("状态", value: sub.status.capitalized)
                if let ts = sub.renewalAt {
                    LabeledContent(
                        "续期日",
                        value: Date(timeIntervalSince1970: TimeInterval(ts))
                            .formatted(date: .abbreviated, time: .omitted)
                    )
                }
            } else {
                Text("免费版").foregroundStyle(.secondary)
            }

            if let c = session.credits {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("本周期额度")
                        Spacer()
                        Text("\(c.used) / \(c.quota)").monospacedDigit()
                    }
                    ProgressView(value: c.percentUsed)
                }
            }
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section {
            Toggle("默认显示字幕", isOn: $subtitlesVisibleByDefault)
        } header: {
            Text("通用")
        } footer: {
            Text("新建项目时字幕轨道默认可见。随时可以在时间线上手动切换。")
        }
    }

    // MARK: - Speech language

    @ViewBuilder
    private var speechSection: some View {
        Section {
            Picker("识别语言", selection: $editorLanguageRaw) {
                Text("自动").tag("automatic")
                Text("中文").tag("chinese")
                Text("英语").tag("english")
            }
        } header: {
            Text("视频剪辑")
        } footer: {
            Text("选择视频中主要的说话语言。Cutti 会据此自动识别字幕。选「自动」时跟随系统语言。")
        }
    }

    // MARK: - Interface language

    @ViewBuilder
    private var interfaceSection: some View {
        Section {
            Picker("界面语言", selection: $uiLanguage) {
                Text("跟随系统").tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh-Hans")
            }
            .onChange(of: uiLanguage) { _, newValue in
                if newValue != initialUILanguage {
                    showRestartPrompt = true
                }
            }
        } header: {
            Text("界面语言")
        } footer: {
            Text("独立于上方识别语言。切换后需要重新打开 App 才能完全生效。")
        }
    }

    // MARK: - Developer

    @ViewBuilder
    private var developerSection: some View {
        Section {
            Toggle("显示 AI 执行轨迹", isOn: $showAgentTrace)
        } header: {
            Text("开发者")
        } footer: {
            Text("在 AI 执行过程中显示每一步的详细日志。日常使用无需打开。")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: appVersionLabel)
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - Reusable auth sheet

/// Standalone sign-in / sign-up sheet pulled out of AccountSheet so
/// Settings can present it too. The original AccountSheet still
/// exists as a thin wrapper used by the "present sign-in" button
/// paths that don't go through Settings.
struct AccountAuthSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = RelaySession.shared

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var mode: Mode
    @State private var isSubmitting = false
    @State private var submitError: String?

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "登录"
        case signUp = "注册"
        var id: String { rawValue }
    }

    init(initialMode: Mode) {
        self._mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationStack {
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
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                }

                if let err = submitError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.footnote)
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
            }
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
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
            dismiss()
        } catch {
            submitError = (error as NSError).localizedDescription
        }
    }
}

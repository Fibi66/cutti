import SwiftUI

/// Video Editor page — speech recognition + interface language. The
/// interface-language picker triggers a restart prompt (handled by the
/// shell, which observes `editorLanguageRaw` / `uiLanguage` changes).
///
/// Uses the legacy AppStorage keys so changing language here behaves
/// identically to the old Form-based Settings.
struct EditorSection: View {
    @AppStorage(CuttiSettings.editorLanguageKey)
    private var editorLanguageRaw: String = EditorLanguagePreference.automatic.rawValue
    @AppStorage(CuttiSettings.uiLanguageKey)
    private var uiLanguage: String = CuttiSettings.uiLanguageSystem

    /// Captured when the section appears so we can detect a real change
    /// vs. just initial value reads when prompting for a restart.
    @State private var initialUILanguage: String = CuttiSettings.uiLanguageSystem
    @State private var showRestartPrompt: Bool = false

    private var editorLanguage: EditorLanguagePreference {
        EditorLanguagePreference(rawValue: editorLanguageRaw) ?? .automatic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Video Editor",
                sub: "Speech and language preferences."
            )

            SettingsCard(padding: nil) {
                SettingsRow(
                    label: "Speech recognition",
                    sub: "Used by local Whisper to generate subtitles."
                ) {
                    Menu {
                        ForEach(EditorLanguagePreference.allCases) { language in
                            Button {
                                editorLanguageRaw = language.rawValue
                            } label: { T(LocalizedStringKey(language.title)) }
                        }
                    } label: {
                        menuLabel(text: editorLanguage.title)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                SettingsRow(
                    label: "Interface language",
                    sub: "Changing this restarts Cutti.",
                    divider: false
                ) {
                    Menu {
                        Button { uiLanguage = CuttiSettings.uiLanguageSystem } label: { T("System") }
                        Button { uiLanguage = CuttiSettings.uiLanguageEnglish } label: { T("English") }
                        Button { uiLanguage = CuttiSettings.uiLanguageChinese } label: { T("Chinese") }
                    } label: {
                        menuLabel(text: uiLanguageDisplay)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear { initialUILanguage = uiLanguage }
        .onChange(of: uiLanguage) { _, newValue in
            if newValue != initialUILanguage {
                showRestartPrompt = true
            }
        }
        .alert(L("Restart Required"), isPresented: $showRestartPrompt) {
            Button(role: .cancel) {
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

    private var uiLanguageDisplay: String {
        switch uiLanguage {
        case CuttiSettings.uiLanguageEnglish: return L("System  ·  English")
        case CuttiSettings.uiLanguageChinese: return L("System  ·  Chinese")
        default:                              return L("System")
        }
    }

    private func menuLabel(text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(SettingsTheme.bodyRegular)
                .foregroundStyle(SettingsTheme.text)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SettingsTheme.textFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: SettingsTheme.controlHeightMedium)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius)
                .fill(SettingsTheme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius)
                .strokeBorder(SettingsTheme.border, lineWidth: 1)
        )
    }

    /// Identical relaunch logic to the legacy SettingsView.
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

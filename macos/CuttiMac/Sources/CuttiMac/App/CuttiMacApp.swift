import AppKit
import AVFoundation
import SwiftUI
import CuttiKit

/// Global pointer to the currently-active editor ViewModel, used by
/// menu-bar commands (Edit ▸ Undo / Redo, etc.) so Cmd+Z works
/// regardless of which subview has keyboard focus. `@FocusedObject`
/// alone is fragile — after a drag-drop or a click on a non-focusable
/// view, the focus chain breaks and the command vanishes. This shared
/// reference is always correct as long as the editor is on screen.
@MainActor
final class ActiveEditor: ObservableObject {
    static let shared = ActiveEditor()
    @Published private(set) var viewModel: MediaCoreViewModel?
    private init() {}

    func setActive(_ vm: MediaCoreViewModel) { viewModel = vm }
    func clearIfActive(_ vm: MediaCoreViewModel) {
        if viewModel === vm { viewModel = nil }
    }
}

/// Low-level NSEvent monitor that catches Cmd+Z / Cmd+Shift+Z
/// BEFORE SwiftUI's responder chain has a chance to swallow the
/// event. SwiftUI's `CommandGroup(replacing: .undoRedo)` has proven
/// unreliable after drag-drop — the focus chain is empty, the menu
/// item disappears, and the shortcut never fires. A local monitor
/// hooked into the shared NSApplication event stream bypasses the
/// whole responder mess: as long as the app is foregrounded and an
/// editor is active, the handler runs.
@MainActor
final class UndoKeyMonitor {
    static let shared = UndoKeyMonitor()
    private var monitor: Any?
    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+Z / Cmd+Shift+Z only.
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "z" else {
                return event
            }
            // Let text fields / text views keep native per-character undo.
            // Editors and timeline surfaces are not NSText* subclasses, so
            // this check protects only what we want to protect.
            if let responder = NSApp.keyWindow?.firstResponder,
               responder.isKind(of: NSText.self) || responder.isKind(of: NSTextView.self) {
                return event
            }
            guard let vm = ActiveEditor.shared.viewModel else { return event }
            let isRedo = event.modifierFlags.contains(.shift)
            DispatchQueue.main.async {
                if isRedo {
                    if vm.canRedo { vm.redo() }
                } else {
                    if vm.canUndo { vm.undo() }
                }
            }
            return nil // Swallow so SwiftUI/menu doesn't double-fire.
        }
    }
}

/// Global monitor for transport keys (Space / J / K / L) that need to
/// toggle playback without stealing keystrokes from any text surface.
/// SwiftUI's `.onKeyPress(.space)` on an ancestor view unconditionally
/// swallows the space key before the IME composition layer gets a
/// chance to select a candidate, which breaks Chinese/Japanese input.
/// A local NSEvent monitor lets us look at the current first responder
/// and any marked text before deciding whether to handle the key, so
/// typing into a TextField / TextEditor / IME composition always wins.
@MainActor
final class TransportKeyMonitor {
    static let shared = TransportKeyMonitor()
    private var monitor: Any?
    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Never hijack keys when modifiers (Cmd/Ctrl/Opt) are held —
            // those are menu or app-level shortcuts, not transport keys.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !modifiers.contains(.command),
                  !modifiers.contains(.control),
                  !modifiers.contains(.option) else {
                return event
            }

            // If a text surface is first responder OR is composing IME
            // marked text, forward the key. Covers NSText/NSTextView as
            // well as wrapper surfaces that delegate to a field editor.
            if let window = NSApp.keyWindow,
               let responder = window.firstResponder {
                if responder.isKind(of: NSText.self) || responder.isKind(of: NSTextView.self) {
                    return event
                }
                if let textView = responder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }
                if window.fieldEditor(false, for: nil) === responder {
                    return event
                }
            }

            guard let vm = ActiveEditor.shared.viewModel else { return event }

            switch event.keyCode {
            case 49: // Space
                DispatchQueue.main.async {
                    guard let player = vm.player else { return }
                    if player.rate > 0 {
                        player.pause()
                    } else {
                        player.playImmediately(atRate: Float(vm.playbackRate))
                    }
                }
                return nil
            case 38: // J
                DispatchQueue.main.async {
                    guard let player = vm.player else { return }
                    let current = player.currentTime().seconds
                    let newTime = max(0, current - 5)
                    player.seek(
                        to: CMTime(seconds: newTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                return nil
            case 40: // K
                DispatchQueue.main.async { vm.player?.pause() }
                return nil
            case 37: // L
                DispatchQueue.main.async {
                    guard let player = vm.player else { return }
                    if player.rate == 0 {
                        player.playImmediately(atRate: Float(vm.playbackRate))
                    } else {
                        let newRate = min(4.0, Double(player.rate) * 2)
                        player.rate = Float(newRate)
                    }
                }
                return nil
            default:
                return event
            }
        }
    }
}

/// Dismisses text-field first responder status when the user clicks
/// outside any text surface. SwiftUI TextFields hold on to focus on
/// macOS even after the user clicks on a non-focusable area (e.g. the
/// video preview), which meant subsequent Space presses kept going
/// into the text field instead of toggling playback. A local NSEvent
/// monitor for leftMouseDown gives us the click location; if the hit
/// view isn't part of a text editor we tell the window to resign first
/// responder so transport keys resume working.
@MainActor
final class ClickFocusResigner {
    static let shared = ClickFocusResigner()
    private var monitor: Any?
    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let responder = window.firstResponder else {
                return event
            }

            // Popovers and sheets host their content in auxiliary
            // windows (e.g. _NSPopoverWindow). A click inside such a
            // window must never resign first responder — doing so
            // collapses the popover before the click can reach its
            // Save / Cancel buttons. We only want this resigner to
            // operate inside the main editor window.
            let className = String(describing: type(of: window))
            if className.contains("Popover") || className.contains("Panel") {
                return event
            }
            if window.parent != nil {
                return event
            }

            // Only act when focus is currently on a text surface; if
            // it's already elsewhere there's nothing to resign.
            let responderIsText = responder.isKind(of: NSText.self)
                || responder.isKind(of: NSTextView.self)
                || window.fieldEditor(false, for: nil) === responder
            guard responderIsText else { return event }

            // SwiftUI TextFields live inside AppKitWindowHostingView,
            // which means hitTest returns the hosting view (NOT an
            // NSText) even when the click lands directly on the field
            // editor. So before doing a recursive hit-test walk, check
            // whether the click is inside the responder's own frame —
            // if it is, the click is meant for the text surface and
            // we must keep focus there. This was killing inline
            // subtitle editing on the very first focus grant.
            if let responderView = responder as? NSView {
                let frameInWindow = responderView.convert(responderView.bounds, to: nil)
                if frameInWindow.contains(event.locationInWindow) {
                    return event
                }
            }

            // Convert click to window coords and find the hit view. If
            // that view (or any ancestor) is an NSText/NSTextView, the
            // click landed inside a text field — keep focus there.
            let locationInWindow = event.locationInWindow
            guard let contentView = window.contentView,
                  let hit = contentView.hitTest(
                    contentView.convert(locationInWindow, from: nil)
                  ) else {
                print("📝 ClickFocusResigner: no hit → resign (responder=\(type(of: responder)))")
                window.makeFirstResponder(nil)
                return event
            }

            var node: NSView? = hit
            while let current = node {
                if current.isKind(of: NSText.self)
                    || current.isKind(of: NSTextView.self) {
                    return event
                }
                node = current.superview
            }

            // Click landed outside text — drop focus so Space / J / K / L
            // resume controlling playback.
            print("📝 ClickFocusResigner: click outside text → resign (responder=\(type(of: responder)), hit=\(type(of: hit)))")
            DispatchQueue.main.async {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}

@main
struct CuttiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var registry: ProjectRegistry
    @State private var activeProjectID: UUID?

    init() {
        // Register bundled fonts (Inter + JetBrains Mono) BEFORE any
        // other init step so the very first SwiftUI view can resolve
        // them. Idempotent — safe even if a previous process registered
        // the same fonts (CoreText returns "already registered" which
        // we treat as success). See SettingsFontRegistrar for details.
        SettingsFontRegistrar.registerAll()

        CuttiSettings.ensureDefaults()
        // Apply UI language override (system / en / zh-Hans) before any
        // SwiftUI view materializes so all LocalizedStringKeys resolve
        // against the chosen bundle from the very first frame.
        CuttiSettings.applyUILanguageOverride()

        // Force-init the relay session so its keychain-seeded credential
        // snapshot is populated before any AI call. Otherwise the first
        // AI request to fire BEFORE the user opens Settings (or the
        // first analyze-record path) hits `currentBearerToken()` — a
        // nonisolated static that reads the snapshot directly without
        // ever instantiating `RelaySession.shared` — sees an empty
        // snapshot, sends no Authorization header, and gets a 401 even
        // for users who are signed in.
        _ = RelaySession.shared

        // Force-init Sparkle so its controller wires itself into the
        // run-loop before the first window appears. Background update
        // checks need to see the app become active, which happens
        // moments after SwiftUI brings the WindowGroup up. On Mac App
        // Store builds this is a no-op (controller stays nil; see
        // `SparkleUpdater`).
        _ = SparkleUpdater.shared

        // Make AppKit tooltips appear after ~300ms instead of the
        // default ~1s. AppKit reads this UserDefaults key at launch to
        // seed NSToolTipManager's initial delay, so we set it here
        // before any window is built.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 300
        ])

        let baseDirectory = AppEnvironment.makeDefaultProjectRoot()
        let reg = ProjectRegistry(baseDirectory: baseDirectory)

        do {
            try reg.loadAll()
            try reg.migrateLegacyIfNeeded()
        } catch {
            print("Warning: Failed to load project registry: \(error)")
        }

        // Surface runtime warning for non-native Apple Silicon
        let arch = RuntimeArchitecture.current()
        if let warning = arch.warningMessage {
            print("⚠️  cutti runtime warning: \(warning)")
        }

        _registry = StateObject(wrappedValue: reg)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let projectID = activeProjectID,
                   let project = registry.projects.first(where: { $0.id == projectID }) {
                    EditorSessionContainer(
                        projectID: projectID,
                        projectName: project.name,
                        registry: registry,
                        onBack: { activeProjectID = nil }
                    )
                    .id(projectID)
                } else {
                    ProjectDashboardView(
                        registry: registry,
                        onOpenProject: { id in
                            activeProjectID = id
                        }
                    )
                }
            }
            .frame(
                minWidth: 1080, idealWidth: 1440, maxWidth: .infinity,
                minHeight: 640, idealHeight: 900, maxHeight: .infinity
            )
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { EditCommands() }
        // Hide the system title bar so the project / dashboard topbar
        // sits flush at the top of the window — Figma / 剪映 style.
        // Traffic-light buttons remain at their default top-left
        // position; the topbars below add explicit leading padding
        // to leave room for them, see `EditorWithBackButton` and
        // `ProjectDashboardView`.
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(SparkleUpdater.shared)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Edit Menu (Undo / Redo)

struct EditCommands: Commands {
    @ObservedObject private var active = ActiveEditor.shared
    @FocusedObject var focusedViewModel: MediaCoreViewModel?

    @AppStorage("timeline.pointsPerSecond") private var pointsPerSecond: Double = 12
    private static let minPPS: Double = 4
    private static let maxPPS: Double = 400
    private static let zoomStep: Double = 1.4

    /// Prefer the focused VM (multi-window aware) and fall back to the
    /// globally-active VM when the focus chain is broken — which happens
    /// routinely after drag-drop, clicking on non-focusable views, etc.
    private var viewModel: MediaCoreViewModel? {
        focusedViewModel ?? active.viewModel
    }

    private var canDelete: Bool {
        guard let vm = viewModel else { return false }
        return vm.selectedSubtitleID != nil || !vm.selectedSegmentIDs.isEmpty
    }

    private func performDelete() {
        guard let vm = viewModel else { return }
        if let cueID = vm.selectedSubtitleID {
            vm.removeSubtitleEntry(id: cueID)
        } else {
            vm.deleteSelectedSegments()
        }
    }

    private func zoom(by factor: Double) {
        let next = (pointsPerSecond * factor)
            .clamped(to: Self.minPPS ... Self.maxPPS)
        pointsPerSecond = next
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button { viewModel?.undo() } label: { T("Undo") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(viewModel?.canUndo ?? false))

            Button { viewModel?.redo() } label: { T("Redo") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(viewModel?.canRedo ?? false))
        }

        // Global Delete so pressing Delete works even when the timeline
        // view isn't the first responder (e.g., right after an export
        // sheet closes or focus lands on a non-focusable container).
        CommandGroup(after: .pasteboard) {
            Divider()
            Button { performDelete() } label: { T("Delete Selection") }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!canDelete)
        }

        // Timeline zoom shortcuts. The slider in TimelineDock writes to
        // the same @AppStorage key, so all three stay in sync.
        CommandMenu(L("View")) {
            Button { zoom(by: Self.zoomStep) } label: { T("Zoom In Timeline") }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(pointsPerSecond >= Self.maxPPS - 0.001)

            Button { zoom(by: 1.0 / Self.zoomStep) } label: { T("Zoom Out Timeline") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(pointsPerSecond <= Self.minPPS + 0.001)

            Button { pointsPerSecond = 12 } label: { T("Reset Timeline Zoom") }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Force the entire app's AppKit chrome into dark aqua so
        // SwiftUI's `.preferredColorScheme(.dark)` (which only sets the
        // SwiftUI environment) doesn't leave SecureField / Picker /
        // ProgressView / system menu surfaces rendering with light
        // chrome on light-mode systems. The redesigned Settings is
        // dark-only by design, and the editor already declares
        // `.preferredColorScheme(.dark)` on its WindowGroup, so making
        // the entire process dark matches existing behavior + fixes
        // the Settings light-mode leakage in one go.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyAppDisplayName()
        // One-time self-check: print a summary of the bundled animation
        // skill so users can confirm in Console that the resource
        // pipeline is wired and the agent will see the baked guidance.
        let entries = AnimationSkill.allEntries
        let baked = AnimationSkill.bakedIntoOverlayPrompt
        print("🎨 [animation.skill] entries=\(entries.count) baked_bytes=\(baked.utf8.count) baked_ok=\(!baked.isEmpty && baked.contains("Three house styles") && baked.contains("Entrance / hold / exit thirds"))")
        // Touching the Qwen3-ASR sidecar manager here arms its
        // willTerminate observer up front so a quit during an active
        // transcription always reaches `stopSynchronously()` — even
        // if the user never opens Settings → Qwen3-ASR. Lazy `init`
        // is otherwise driven by Settings UI / first transcription,
        // and either of those could miss the registration window.
        //
        // We also kick off a prewarm whenever the Qwen3-ASR sidecar
        // is installed and the host can run it. Cold model load takes
        // ~30-90s, which would otherwise be paid by the first
        // transcription request and frequently exceed the boot
        // health-check budget. Prewarming at app launch hides that
        // latency — by the time the user clicks "Generate subtitles"
        // the sidecar is hot in MPS memory.
        _ = QwenAsrSidecarManager.shared
        QwenAsrSidecarManager.shared.prewarmIfReady()
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            self.applyAppDisplayName()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders: the manager already listens for the
        // same notification, but registering twice is harmless and
        // protects us if the Notification-center observer was ever
        // cleaned up (e.g. a future refactor).
        QwenAsrSidecarManager.shared.stopSynchronously()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            self.applyAppDisplayName()
        }
    }

    /// Called by AppKit after every event-loop pass. SwiftUI rebuilds
    /// `NSApp.mainMenu` whenever a `.commands { ... }` body
    /// re-evaluates — which happens any time `@FocusedObject` (or any
    /// other observed value the Commands struct consumes) changes,
    /// for example when the user clicks from a focusable surface
    /// (transcript editor, chat composer) to a non-focusable area.
    /// Each rebuild restores AppKit's CFBundleName-derived default
    /// titles, flipping the menu bar's bold app name back from the
    /// localized brand ("小剪") to the bundle name ("Cutti") and
    /// the standard items back to "About Cutti" / "Hide Cutti" /
    /// "Quit Cutti".
    ///
    /// `applicationDidBecomeActive` doesn't fire on intra-window
    /// focus changes, so re-applying there is not enough. Hooking
    /// `applicationDidUpdate` keeps the menu visually stable through
    /// every SwiftUI command rebuild. The rewrite is idempotent —
    /// `applyAppDisplayName()` early-exits when the display name
    /// already matches the process name, and the per-item check
    /// (`title.contains(old)`) skips items that have already been
    /// rewritten — so the per-call cost is a couple of microseconds.
    func applicationDidUpdate(_ notification: Notification) {
        applyAppDisplayName()
    }

    /// Replace every occurrence of the SwiftPM-derived process name
    /// ("CuttiMac") in the menu bar and window titles with the
    /// localized brand name (English: "Cutti", Simplified Chinese:
    /// "小剪"). SwiftPM apps have no Info.plist, so this is the
    /// pragmatic way to ship a real product name without changing the
    /// executable target name (which would churn hundreds of
    /// `@testable import CuttiMac` references).
    private func applyAppDisplayName() {
        let displayName = L("__app_name__")
        let processName = ProcessInfo.processInfo.processName
        guard displayName != processName else { return }

        if let mainMenu = NSApp.mainMenu {
            rewriteMenu(mainMenu, from: processName, to: displayName)
        }
        for window in NSApp.windows {
            // Only rewrite plain executable titles — leave custom
            // titles (e.g. project names) alone.
            if window.title == processName || window.title.isEmpty {
                window.title = displayName
            }
        }
    }

    private func rewriteMenu(_ menu: NSMenu, from old: String, to new: String) {
        if menu.title.contains(old) {
            menu.title = menu.title.replacingOccurrences(of: old, with: new)
        }
        for item in menu.items {
            // Re-target the standard About menu item to our custom
            // handler so the About panel shows the localized name.
            if item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) {
                item.target = self
                item.action = #selector(showAboutPanel(_:))
            }
            if item.title.contains(old) {
                item.title = item.title.replacingOccurrences(of: old, with: new)
            }
            if let submenu = item.submenu {
                rewriteMenu(submenu, from: old, to: new)
            }
        }
    }

    /// Custom About panel so it shows the localized brand name instead
    /// of the SwiftPM executable name. Wired via the standard
    /// `applicationName` override key.
    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: L("__app_name__")
        ])
    }
}

import SwiftUI
import CuttiKit
import os

private let launchLog = Logger(subsystem: "app.cutti.ios", category: "launch")

/// Emit a launch-phase diagnostic line to BOTH os.Logger (unified
/// log, visible in Console.app / `log stream`) and NSLog (legacy ASL
/// channel, visible to `idevicesyslog`). Using NSLog instead of plain
/// `print` is important on iOS 26 where stderr from apps no longer
/// reaches the device syslog socket — NSLog still does.
private func launchTrace(_ message: String) {
    launchLog.log("\(message, privacy: .public)")
    NSLog("[cutti.launch] %@", message)
}

@main
struct CuttiMobileApp: App {
    @StateObject private var appState: AppState

    init() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        launchTrace("app launching — version=\(version) build=\(build)")
        NSSetUncaughtExceptionHandler { ex in
            let stack = ex.callStackSymbols.joined(separator: "\n")
            let line = "uncaught ObjC exception: \(ex.name.rawValue) reason=\(ex.reason ?? "") stack=\(stack)"
            launchLog.fault("\(line, privacy: .public)")
            print("[cutti.launch] FAULT \(line)")
        }
        _appState = StateObject(wrappedValue: {
            let s = AppState()
            launchTrace("AppState ready; projects=\(s.registry.projects.count)")
            return s
        }())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.registry)
                .preferredColorScheme(.dark)
                .onAppear { launchTrace("RootView onAppear") }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var currentProject: ProjectInfo?
    @Published var currentDocument: ProjectDocument?
    /// In-memory clipboard for segments (⌘C / ⌘X / ⌘V). Lives on
    /// AppState so a segment copied out of one project can be pasted
    /// into another within the same app session. Not persisted — the
    /// clipboard empties on relaunch and is not shared across apps.
    @Published var segmentClipboard: TimelineSegment?
    let registry: ProjectRegistry

    init() {
        let base = Self.defaultBaseDirectory()
        self.registry = ProjectRegistry(baseDirectory: base)
        do {
            try registry.loadAll()
            launchTrace("registry loaded; projects=\(self.registry.projects.count)")
        } catch {
            let line = "ProjectRegistry load failed: \(String(describing: error))"
            launchLog.error("\(line, privacy: .public)")
            print("[cutti.launch] ERROR \(line)")
        }
    }

    func open(_ project: ProjectInfo) {
        let root = registry.projectRoot(for: project.id)
        let manifestPath = root.appending(path: "media/manifest.json").path
        let manifestExists = FileManager.default.fileExists(atPath: manifestPath)
        launchTrace("open project id=\(project.id.uuidString.prefix(8)) name=\(project.name) root=\(root.path) manifestExists=\(manifestExists)")
        currentProject = project
        let doc = ProjectDocument(
            project: project,
            rootDirectory: root
        )
        doc.load()
        launchTrace("open loaded doc tracks=\(doc.tracks.count) primarySegs=\(doc.tracks.first?.segments.count ?? 0) media=\(doc.manifest.media.count)")
        currentDocument = doc
        try? registry.updateLastOpened(id: project.id)
    }

    func closeProject() {
        launchTrace("closeProject — was=\(currentProject?.id.uuidString.prefix(8) ?? "nil")")
        currentProject = nil
        currentDocument = nil
    }

    private static func defaultBaseDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = support.appending(path: "cutti", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

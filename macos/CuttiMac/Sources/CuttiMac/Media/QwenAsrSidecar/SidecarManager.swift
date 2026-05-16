import AppKit
import Combine
import Foundation

/// Lifecycle owner for the Qwen3-ASR sidecar process. Singleton-on-
/// MainActor so SwiftUI views can `@ObservedObject SidecarManager.shared`
/// to bind install + run state into Settings UI without ad-hoc
/// notification plumbing.
///
/// Concurrency model:
/// - All published state mutates on the main actor.
/// - Long-running install / boot work runs in detached `Task`s that
///   funnel completion + progress back via `MainActor.run { ... }`.
/// - The Process and its pipes live on background dispatch queues
///   (set up by Foundation) so we never block the main thread on
///   subprocess I/O.
@MainActor
final class QwenAsrSidecarManager: ObservableObject {

    /// Coarse view-model state for the Settings UI. Granular install
    /// progress is in a separate published property to avoid emitting
    /// state-machine churn on every percent tick.
    enum InstallState: Equatable {
        case unsupported(reason: String)
        case notInstalled
        case installing
        case installed(QwenAsrSidecarManifest)
        case failed(String)
    }

    enum RunState: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
        case sessionDisabled    // circuit breaker tripped
    }

    static let shared = QwenAsrSidecarManager()

    @Published private(set) var installState: InstallState
    @Published private(set) var runState: RunState = .stopped
    @Published private(set) var installPhase: QwenAsrInstallPhase = .preflight
    @Published private(set) var overallProgress: Double = 0.0
    @Published private(set) var lastError: String?

    /// Token generated per-launch and handed to /transcribe via
    /// Authorization header. Refreshed every time the sidecar process
    /// starts so a stale value lingering in env vars doesn't confuse
    /// subsequent runs.
    private(set) var authToken: String?

    private var process: Process?
    private var startTask: Task<Void, Error>?
    private var installTask: Task<Void, Never>?

    private var consecutiveBootFailures: Int = 0
    private var willTerminateObserver: NSObjectProtocol?

    private init() {
        // Resolve initial install state synchronously so the Settings
        // UI doesn't flash "Not installed" on a pre-installed user.
        self.installState = Self.resolveInstallStateOnDisk()
        registerWillTerminate()
    }

    // No deinit: the manager is a singleton (`shared`) so it lives
    // for the entire process. willTerminateObserver leaks into the
    // notification center for the same lifetime, which is fine. If
    // we ever make this non-singleton, add observer removal back —
    // Swift 6 strict-concurrency makes deinit access to non-Sendable
    // captured properties an error, so it'd need to be reworked.

    // MARK: - Public API

    /// True when the sidecar is installed AND the host is supported.
    /// Settings UI uses this to grey out the "use Qwen first" toggle.
    var isAvailable: Bool {
        if case .installed = installState { return true }
        return false
    }

    /// True when an install is currently in flight. The Settings UI
    /// uses this to switch the primary button into a progress bar.
    var isInstalling: Bool {
        if case .installing = installState { return true }
        return false
    }

    /// Called from `applicationDidFinishLaunching`. Spawns the sidecar
    /// in the background so the model is hot in MPS memory by the
    /// time the first transcription request arrives — saving the
    /// user a 30-90s cold-start wait per session.
    ///
    /// Silently no-ops if the sidecar isn't installed, the host isn't
    /// supported, or the build isn't direct-distribution. Failures
    /// are logged but don't surface in the UI; the regular
    /// `ensureRunning()` path will retry on first transcription.
    func prewarmIfReady() {
        guard CuttiDistribution.current == .direct else {
            print("🎤 qwen-asr: prewarm skipped (not direct distribution).")
            return
        }
        guard case .installed = installState else {
            print("🎤 qwen-asr: prewarm skipped (not installed).")
            return
        }
        if case .running = runState { return }
        if case .starting = runState { return }
        print("🎤 qwen-asr: prewarming sidecar at app launch...")
        Task {
            do {
                let started = Date()
                let result = try await QwenAsrSidecarManager.shared.ensureRunning()
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "🎤 qwen-asr: prewarm ready on port %d in %.1fs.", result.port, elapsed))
            } catch {
                print("🎤 qwen-asr: prewarm failed: \(error.localizedDescription). " +
                      "Will retry on first transcription.")
            }
        }
    }

    /// Begins (or resumes) an install. Idempotent — subsequent calls
    /// while installing throw `alreadyInstalling`.
    func install() {
        guard installTask == nil else { return }
        guard !isInstalling else { return }

        // Preflight first so we surface unsupported-host failures
        // before showing a progress UI.
        do {
            try QwenAsrSidecarInstaller.preflight()
        } catch {
            installState = unsupportedOrFailed(error: error)
            return
        }

        installState = .installing
        overallProgress = 0
        installPhase = .preflight
        lastError = nil

        // The install Task captures the singleton via the shared
        // accessor (rather than `[weak self]`) for two reasons: (a)
        // SidecarManager is a singleton, so weak-self is meaningless,
        // and (b) the strict-concurrency checker rejects passing a
        // weak `self` through the Sendable progress closure into a
        // nested Task. The shared lookup is allocation-free.
        installTask = Task {
            do {
                try await QwenAsrSidecarInstaller.install(progress: { phase, frac in
                    Task { @MainActor in
                        let m = QwenAsrSidecarManager.shared
                        m.installPhase = phase
                        let share = phase.overallShare
                        m.overallProgress = min(1.0, share.start + share.length * frac)
                    }
                })
                await MainActor.run {
                    let m = QwenAsrSidecarManager.shared
                    m.overallProgress = 1.0
                    if let manifest = QwenAsrSidecarInstaller.loadManifest() {
                        m.installState = .installed(manifest)
                        // Auto-prewarm right after a fresh install so the
                        // user's first transcribe doesn't pay the full
                        // cold-import + model-load tax (which on a fresh
                        // venv — no .pyc cache, no MPS warmup — can blow
                        // past the boot deadlines, especially when the
                        // user immediately kicks off "One-click first
                        // cut" and scene-analysis ffmpeg is also
                        // hammering the CPU/disk).
                        m.prewarmIfReady()
                    } else {
                        m.installState = .failed("Install completed but manifest is missing.")
                    }
                    m.installTask = nil
                }
            } catch {
                await MainActor.run {
                    let m = QwenAsrSidecarManager.shared
                    m.installState = .failed(error.localizedDescription)
                    m.lastError = error.localizedDescription
                    m.installTask = nil
                }
            }
        }
    }

    /// Tears down the install dir + HF cache. Stops the running
    /// sidecar first.
    func uninstall() async {
        await stop()
        QwenAsrSidecarInstaller.uninstall()
        installState = .notInstalled
        runState = .stopped
        consecutiveBootFailures = 0
        lastError = nil
    }

    /// Starts the sidecar if not already running. Returns the bound
    /// (port, token) pair on success. Throws on circuit-breaker open
    /// / install missing / boot timeout.
    func ensureRunning() async throws -> (port: Int, token: String) {
        if case .running(let port) = runState, let token = authToken {
            // Liveness check: the cached `.running` state can be stale if
            // the python child died and the terminationHandler hasn't
            // been delivered to the main actor yet (or never fires, e.g.
            // a deinit-on-quit race). Verify the Process is actually up
            // before handing out its port; if it's gone, fall through
            // to a fresh boot so the user doesn't see a confusing
            // "connection refused" later in the request path.
            if let proc = process, proc.isRunning {
                print("🎤 qwen-asr: ensureRunning() → cached running on port \(port) (pid=\(proc.processIdentifier)).")
                return (port, token)
            }
            print("🎤 qwen-asr: ensureRunning() → cached state was .running but process is gone; rebooting.")
            // Force a re-boot below. handleProcessExit will (eventually)
            // run on the main actor, but it's idempotent so it's fine.
            process = nil
            authToken = nil
            runState = .failed("Sidecar exited but terminationHandler hadn't fired yet.")
        }
        if case .sessionDisabled = runState {
            throw QwenAsrSidecarError.circuitBreakerOpen
        }
        guard case .installed = installState else {
            throw QwenAsrSidecarError.notInstalled
        }
        print("🎤 qwen-asr: ensureRunning() → state=\(describe(runState)); booting.")

        // Coalesce concurrent ensureRunning() callers onto a single
        // boot attempt — without this, two subtitle-generation jobs
        // racing during app launch would each try to spawn their own
        // sidecar process.
        if let existing = startTask {
            try await existing.value
            if case .running(let port) = runState, let token = authToken {
                return (port, token)
            }
            throw QwenAsrSidecarError.sidecarBootTimeout
        }

        runState = .starting
        let task = Task<Void, Error> { [weak self] in
            try await self?.boot()
        }
        startTask = task
        defer { startTask = nil }
        do {
            try await task.value
        } catch {
            consecutiveBootFailures += 1
            if consecutiveBootFailures >= QwenAsrSidecar.bootFailureThreshold {
                runState = .sessionDisabled
                lastError = "Qwen3-ASR has failed to start \(consecutiveBootFailures) times this session. " +
                            "Restart Cutti to try again."
            } else {
                runState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
            throw error
        }
        consecutiveBootFailures = 0
        guard case .running(let port) = runState, let token = authToken else {
            throw QwenAsrSidecarError.sidecarBootTimeout
        }
        return (port, token)
    }

    /// Synchronous SIGTERM + brief wait. Called from `applicationWill
    /// Terminate` (where async suspension isn't available) so we can
    /// reap the python child before the user's session goes away.
    func stopSynchronously() {
        print("🎤 qwen-asr: stopSynchronously() called (state=\(describe(runState)), pid=\(process?.processIdentifier.description ?? "nil")).")
        // Also terminate any in-flight installer subprocess (pip,
        // huggingface-cli, tar, venv) so we don't leave a multi-GB
        // download running orphaned after the user clicks Quit.
        ActiveSubprocessRegistry.shared.terminateCurrent()
        installTask?.cancel()
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
            // Brief blocking wait. willTerminate gives us ~5s before
            // SIGKILL anyway, so we wait at most 2.
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        process = nil
        runState = .stopped
        authToken = nil
    }

    /// Cooperative async stop. Used by uninstall / explicit "Stop
    /// server" UI button.
    func stop() async {
        print("🎤 qwen-asr: stop() called (state=\(describe(runState)), pid=\(process?.processIdentifier.description ?? "nil")).")
        guard let proc = process else {
            runState = .stopped
            return
        }
        if proc.isRunning {
            proc.terminate()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(5.0)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                cont.resume()
            }
        }
        if proc.isRunning {
            // Hard kill: terminate() = SIGTERM. macOS doesn't expose
            // SIGKILL on Process directly, so reach for `kill` via
            // posix.
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        runState = .stopped
        authToken = nil
    }

    // MARK: - Internals

    private static func resolveInstallStateOnDisk() -> InstallState {
        // Mirror the install-time preflight: this feature is gated to
        // direct-distribution Apple Silicon builds only. We re-check
        // here (not just at install time) so a Mac App Store build
        // that somehow inherits a populated install dir from a
        // sideloaded direct build can't accidentally start the sidecar.
        if CuttiDistribution.current != .direct {
            return .unsupported(reason: "Not available in this build of Cutti.")
        }
        if !qwenAsrHostIsAppleSilicon() {
            return .unsupported(reason: "Apple Silicon Mac required.")
        }
        if QwenAsrSidecarInstaller.isInstallUpToDate(),
           let manifest = QwenAsrSidecarInstaller.loadManifest() {
            return .installed(manifest)
        }
        return .notInstalled
    }

    private func unsupportedOrFailed(error: Error) -> InstallState {
        if case QwenAsrSidecarError.requiresAppleSilicon = error {
            return .unsupported(reason: "Apple Silicon Mac required.")
        }
        if case QwenAsrSidecarError.requiresDirectDistribution = error {
            return .unsupported(reason: "Not available in this build of Cutti.")
        }
        return .failed(error.localizedDescription)
    }

    private func boot() async throws {
        // Refresh bundled sidecar text files (server.py, requirements.txt,
        // VERSION) from the app bundle on every cold start. The Python
        // runtime + venv are NOT touched — only the small handful of
        // editable text files. This lets a fresh Cutti binary ship
        // an updated server.py (e.g. new progress hooks) without
        // forcing the user through the full ~370 MB reinstall flow,
        // since the existing venv is still binary-compatible with
        // the new script as long as the schema version is unchanged.
        try? QwenAsrSidecarInstaller.refreshBundledSidecarScripts()

        // Fresh token per launch — we never reuse the value across
        // process lifetimes, so a leaked auth-token.txt from a
        // previous run can't be used to talk to the new server.
        let token = Self.makeAuthToken()
        try? Self.writeAuthTokenFile(token)
        authToken = token

        try? FileManager.default.removeItem(at: QwenAsrSidecar.portFile)

        let proc = Process()
        proc.executableURL = QwenAsrSidecar.venvPython
        proc.arguments = ["-u", QwenAsrSidecar.serverPy.path]
        proc.currentDirectoryURL = QwenAsrSidecar.installRoot
        proc.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "PORT": "0",
            "QWEN_AUTH_TOKEN": token,
            "QWEN_INSTALL_DIR": QwenAsrSidecar.installRoot.path,
            "HF_HOME": QwenAsrSidecar.huggingFaceCache.path,
            "TRANSFORMERS_VERBOSITY": "error",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
        ]

        // Drain stdout / stderr so the python child never blocks on a
        // full pipe. We tee into the user's app log file so a debug
        // build (or a remote bug report) can pull the most recent
        // server logs without having to know about a separate file.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        let stdoutLines = LineBuffer { line in
            print("🎤 qwen-asr[stdout]: \(line)")
        }
        let stderrLines = LineBuffer { line in
            print("🎤 qwen-asr[stderr]: \(line)")
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdoutLines.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrLines.append(chunk) }
        }

        do {
            try proc.run()
        } catch {
            throw QwenAsrSidecarError.sidecarSpawnFailed(error.localizedDescription)
        }
        process = proc
        proc.terminationHandler = { [weak self] finished in
            // terminationHandler runs on a private background thread.
            Task { @MainActor [weak self] in
                self?.handleProcessExit(status: finished.terminationStatus)
            }
        }

        let port = try await waitForBoot(token: token)
        runState = .running(port: port)
    }

    /// Polls `port.txt` for the bound port, then GET / for HTTP 200,
    /// then health-check. Generous total budget because cold model
    /// load is the dominant cost on first launch — the ASR-1.7B +
    /// ForcedAligner-0.6B weights together are ~5GB of safetensors
    /// to mmap into MPS memory, which on a slow disk + cold page
    /// cache regularly takes 60-120s. We've measured 25-60s warm
    /// and 40-180s cold during bench runs, so 240s leaves a healthy
    /// margin without making genuine failures painful.
    private func waitForBoot(token: String) async throws -> Int {
        let bootStart = Date()
        // 90s rather than 30s: a freshly-installed venv has no `.pyc`
        // cache so the first run pays the full ``compileall`` cost,
        // and on the same launch we're often racing scene-analysis
        // ffmpeg + audio-extract for CPU. A 30s budget proved too
        // tight in the wild — cold imports of torch + qwen_asr alone
        // can hit 25s on contended hardware before the bind even
        // happens. We bias toward letting the local model win over
        // an aggressive fallback to Apple Speech.
        let portDeadline = bootStart.addingTimeInterval(90)
        var port: Int?
        while Date() < portDeadline {
            // Fail fast if the child has already exited — otherwise
            // we'd waste the full budget on a process that's never
            // going to write port.txt.
            if let p = process, !p.isRunning {
                throw QwenAsrSidecarError.sidecarSpawnFailed(
                    "Sidecar exited before binding a port (status \(p.terminationStatus))."
                )
            }
            if let p = readPortFile() {
                port = p
                break
            }
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let resolvedPort = port else {
            throw QwenAsrSidecarError.sidecarBootTimeout
        }
        print(String(format: "🎤 qwen-asr: bound port %d after %.1fs; waiting for model load...",
                     resolvedPort, Date().timeIntervalSince(bootStart)))

        let healthDeadline = bootStart.addingTimeInterval(240)
        let healthURL = URL(string: "http://127.0.0.1:\(resolvedPort)/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var lastLogged = Date()
        while Date() < healthDeadline {
            do {
                let (_, response) = try await session.data(from: healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    print(String(format: "🎤 qwen-asr: ready in %.1fs total.",
                                 Date().timeIntervalSince(bootStart)))
                    return resolvedPort
                }
            } catch {
                // connection refused → server not up yet, retry.
            }
            // Process may have exited during boot; bail early instead
            // of waiting out the full timeout.
            if let p = process, !p.isRunning {
                throw QwenAsrSidecarError.sidecarSpawnFailed(
                    "Sidecar exited during boot (status \(p.terminationStatus))."
                )
            }
            // Heartbeat every 15s so a slow load doesn't look frozen.
            if Date().timeIntervalSince(lastLogged) >= 15 {
                lastLogged = Date()
                print(String(format: "🎤 qwen-asr: still loading (%.0fs elapsed)...",
                             Date().timeIntervalSince(bootStart)))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw QwenAsrSidecarError.sidecarBootTimeout
    }

    private func readPortFile() -> Int? {
        guard let str = try? String(contentsOf: QwenAsrSidecar.portFile, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    private func handleProcessExit(status: Int32) {
        // Could be triggered by stop() (expected) or a crash.
        let pidStr = process?.processIdentifier.description ?? "nil"
        print("🎤 qwen-asr: handleProcessExit pid=\(pidStr) status=\(status) state-was=\(describe(runState)).")
        process = nil
        authToken = nil
        switch runState {
        case .running, .starting:
            // Unexpected exit while we still thought it was up.
            runState = .failed("Sidecar exited unexpectedly (status \(status)).")
        case .stopped, .failed, .sessionDisabled:
            // Already torn down or marked broken — keep the existing
            // state so we don't clobber a more informative error.
            break
        }
    }

    /// Human-readable RunState for diagnostic logging. Keeps the
    /// printable form in one place so adding cases to the enum doesn't
    /// require fixing N call sites.
    private func describe(_ state: RunState) -> String {
        switch state {
        case .stopped: return ".stopped"
        case .starting: return ".starting"
        case .running(let port): return ".running(port=\(port))"
        case .failed(let msg): return ".failed(\(msg))"
        case .sessionDisabled: return ".sessionDisabled"
        }
    }

    private func registerWillTerminate() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willTerminate runs on the main thread; SidecarManager is
            // MainActor so this is reentrancy-safe via a sync hop.
            MainActor.assumeIsolated {
                self?.stopSynchronously()
            }
        }
    }

    private static func makeAuthToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandom shouldn't fail on macOS; fall back to UUIDs
            // doubled up so we still hit ~256 bits of entropy.
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func writeAuthTokenFile(_ token: String) throws {
        let url = QwenAsrSidecar.installRoot.appendingPathComponent("auth-token.txt")
        try token.write(to: url, atomically: true, encoding: .utf8)
        // chmod 600 so other local users on a shared Mac can't read
        // the bearer.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}

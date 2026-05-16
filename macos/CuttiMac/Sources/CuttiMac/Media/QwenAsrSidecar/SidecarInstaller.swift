import CryptoKit
import Foundation

/// One-shot installer for the Qwen3-ASR sidecar. Stateless: every
/// call is a fresh attempt, no retries baked in. The manager handles
/// retry / circuit-breaker policy.
///
/// Each public install step is independently re-runnable: if the
/// process is interrupted between steps, the next call inspects the
/// install dir and skips work that's already on disk. We deliberately
/// avoid writing manifest.json until everything succeeds, so a
/// partial install is detectable by its absence.
struct QwenAsrSidecarInstaller {

    /// Approximate disk needed: ~25MB python tarball, ~70MB extracted,
    /// ~2GB venv (torch + transformers + dependencies), ~3.5GB ASR
    /// model, ~1.2GB aligner model, plus a generous slack for temp
    /// download files and pip's build cache. Round to 8GB to leave
    /// the user a healthy margin.
    static let requiredFreeBytes: Int64 = 8 * 1024 * 1024 * 1024

    typealias ProgressHandler = @Sendable (QwenAsrInstallPhase, Double) -> Void

    /// Runs all install phases in order. Idempotent — already-on-disk
    /// outputs are kept and the corresponding step is skipped. Throws
    /// `QwenAsrSidecarError` on any failure; the manager surfaces the
    /// localized description into the UI.
    static func install(progress: @escaping ProgressHandler) async throws {
        progress(.preflight, 0)
        try preflight()

        // Copy the bundled payload into the install dir so server.py /
        // requirements.txt / VERSION are co-located with the venv. We
        // do this before downloading anything heavy because if the
        // bundle is missing we want to fail fast.
        try copyBundledResources()

        if !FileManager.default.fileExists(atPath: QwenAsrSidecar.pythonBin.path) {
            progress(.downloadingPython, 0)
            let tarball = try await downloadPythonTarball(progress: { f in
                progress(.downloadingPython, f)
            })
            defer { try? FileManager.default.removeItem(at: tarball) }

            progress(.verifyingPython, 0)
            try verifyChecksum(of: tarball, expected: QwenAsrSidecar.Python.sha256Hex)

            progress(.extractingPython, 0)
            try extractPython(tarball: tarball)
        }

        if !FileManager.default.fileExists(atPath: QwenAsrSidecar.venvPython.path) {
            progress(.creatingVenv, 0)
            try createVenv()
        }

        // We always re-run pip install: it's a no-op when nothing
        // changed (pip checks already-installed packages), and it
        // catches the "user upgraded cutti, requirements.txt changed"
        // case automatically.
        progress(.installingPip, 0)
        try installPipDeps(progress: { f in progress(.installingPip, f) })

        // HF download is also idempotent — `huggingface-cli download`
        // skips files already in HF_HOME.
        progress(.downloadingAsrModel, 0)
        try downloadHuggingFaceRepo(QwenAsrSidecar.Models.asrRepo) { f in
            progress(.downloadingAsrModel, f)
        }
        progress(.downloadingAlignerModel, 0)
        try downloadHuggingFaceRepo(QwenAsrSidecar.Models.alignerRepo) { f in
            progress(.downloadingAlignerModel, f)
        }

        progress(.finalising, 0)
        try writeManifest()
        progress(.finalising, 1)
    }

    // MARK: - Phases

    static func preflight() throws {
        guard qwenAsrHostIsAppleSilicon() else {
            throw QwenAsrSidecarError.requiresAppleSilicon
        }
        guard CuttiDistribution.current == .direct else {
            throw QwenAsrSidecarError.requiresDirectDistribution
        }
        let available = try freeBytes(at: QwenAsrSidecar.installRoot)
        guard available >= requiredFreeBytes else {
            throw QwenAsrSidecarError.insufficientFreeSpace(
                required: requiredFreeBytes,
                available: available
            )
        }
    }

    static func copyBundledResources() throws {
        guard let bundledServer = QwenAsrSidecar.bundledServerPy,
              let bundledRequirements = QwenAsrSidecar.bundledRequirementsTxt,
              let bundledVersion = QwenAsrSidecar.bundledVersionFile else {
            throw QwenAsrSidecarError.bundledResourcesMissing
        }
        try copyOverwrite(from: bundledServer, to: QwenAsrSidecar.serverPy)
        try copyOverwrite(from: bundledRequirements, to: QwenAsrSidecar.requirementsTxt)
        try copyOverwrite(from: bundledVersion, to: QwenAsrSidecar.versionFile)
    }

    /// Refresh just the small bundled text files (server.py,
    /// requirements.txt, VERSION) from the app bundle, leaving the
    /// Python runtime and venv untouched. Called from the manager's
    /// `boot()` on every cold start so a new Cutti binary can ship
    /// an updated server.py without forcing a full reinstall. Safe
    /// no-op when the install dir is missing (the caller will pick
    /// that up via `isInstallUpToDate`).
    static func refreshBundledSidecarScripts() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: QwenAsrSidecar.installRoot.path) else { return }
        guard let bundledServer = QwenAsrSidecar.bundledServerPy else { return }
        if let installed = try? Data(contentsOf: QwenAsrSidecar.serverPy),
           let bundled = try? Data(contentsOf: bundledServer),
           installed == bundled {
            return
        }
        try copyOverwrite(from: bundledServer, to: QwenAsrSidecar.serverPy)
        print("🎤 qwen-asr: refreshed server.py from app bundle")
    }

    static func downloadPythonTarball(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutti-qwen-py-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let dest = tmpDir.appendingPathComponent(QwenAsrSidecar.Python.assetName)

        // We attach the progress observer at the SESSION level (rather
        // than passing it as a per-task delegate). Per-task delegate
        // delivery of `URLSessionDownloadDelegate.urlSession(_:downloadTask:
        // didWriteData:...)` has historically been flaky across macOS
        // releases; session-level delegates are the canonical path
        // and are explicitly documented to receive these callbacks.
        let observer = ProgressObserver(handler: progress)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: observer,
            delegateQueue: nil
        )
        defer {
            observer.cancel()
            session.finishTasksAndInvalidate()
        }

        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await withCheckedThrowingContinuation { cont in
                let task = session.downloadTask(with: QwenAsrSidecar.Python.downloadURL)
                observer.completionContinuation = cont
                task.resume()
            }
        } catch {
            throw QwenAsrSidecarError.downloadFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw QwenAsrSidecarError.downloadFailed("HTTP \(code) from python-build-standalone")
        }

        // URLSession stores into a tmp file that disappears when the
        // download delegate returns, so we move it now (still inside
        // the delegate-driven continuation flow, before defer fires).
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: downloaded, to: dest)
        return dest
    }

    static func verifyChecksum(of file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == expected.lowercased() else {
            throw QwenAsrSidecarError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    static func extractPython(tarball: URL) throws {
        // python-build-standalone install_only tarballs contain a top
        // level dir named `python/`. Extracting into installRoot puts
        // it exactly where pythonRoot expects it. We blow away any
        // stale dir first so a half-finished previous extract doesn't
        // mix old + new files.
        try? FileManager.default.removeItem(at: QwenAsrSidecar.pythonRoot)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tarball.path, "-C", QwenAsrSidecar.installRoot.path]
        let stderr = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw QwenAsrSidecarError.extractionFailed(error.localizedDescription)
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errBytes: Data = (try? stderr.fileHandleForReading.readToEnd()) ?? nil ?? Data()
            let err = String(data: errBytes, encoding: .utf8) ?? ""
            throw QwenAsrSidecarError.extractionFailed("tar exit \(proc.terminationStatus): \(err)")
        }
        guard FileManager.default.fileExists(atPath: QwenAsrSidecar.pythonBin.path) else {
            throw QwenAsrSidecarError.extractionFailed("python3 not found at expected path after extract")
        }
    }

    static func createVenv() throws {
        try? FileManager.default.removeItem(at: QwenAsrSidecar.venvRoot)
        let result = try runProcess(
            executable: QwenAsrSidecar.pythonBin,
            arguments: ["-m", "venv", QwenAsrSidecar.venvRoot.path],
            workingDirectory: QwenAsrSidecar.installRoot,
            extraEnv: [:]
        )
        guard result.exitStatus == 0 else {
            throw QwenAsrSidecarError.venvCreationFailed("python -m venv exit \(result.exitStatus): \(result.stderr)")
        }
        guard FileManager.default.fileExists(atPath: QwenAsrSidecar.venvPython.path) else {
            throw QwenAsrSidecarError.venvCreationFailed("venv python3 missing after create")
        }
    }

    static func installPipDeps(progress: @Sendable @escaping (Double) -> Void) throws {
        // `--no-input`: never ask for keyring auth. `--upgrade-strategy
        // only-if-needed`: don't churn already-pinned transitive deps.
        // `--progress-bar off`: pip's own bar uses \r and is messy in
        // the parent's stdout pipe; we don't try to parse it.
        let args = [
            "-m", "pip", "install",
            "--no-input",
            "--no-cache-dir",
            "--progress-bar", "off",
            "--disable-pip-version-check",
            "-r", QwenAsrSidecar.requirementsTxt.path,
        ]
        let result = try runProcess(
            executable: QwenAsrSidecar.venvPython,
            arguments: args,
            workingDirectory: QwenAsrSidecar.installRoot,
            extraEnv: ["PIP_DISABLE_PIP_VERSION_CHECK": "1"],
            onStderrLine: { line in
                // Best-effort coarse progress: count "Collecting" lines
                // and divide by approximate total. This is just a hint
                // for the bar — exact pip totals aren't stable.
                if line.hasPrefix("Collecting ") {
                    Self.pipCollectedCount.withLock { $0 += 1 }
                    let count = Self.pipCollectedCount.withLock { $0 }
                    progress(min(0.9, Double(count) / 80.0))
                } else if line.hasPrefix("Successfully installed") {
                    progress(1.0)
                }
            }
        )
        Self.pipCollectedCount.withLock { $0 = 0 }
        guard result.exitStatus == 0 else {
            throw QwenAsrSidecarError.pipInstallFailed(
                "pip exit \(result.exitStatus). Last 4kB of stderr: \(result.stderr.suffix(4096))"
            )
        }
    }

    static func downloadHuggingFaceRepo(
        _ repo: String,
        progress: @Sendable @escaping (Double) -> Void
    ) throws {
        let env: [String: String] = [
            "HF_HOME": QwenAsrSidecar.huggingFaceCache.path,
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
        ]
        // huggingface-cli prints `Downloading 'X.safetensors' (size)` /
        // `... done` lines per file. We tick a smoothed count toward
        // 1.0 — exact byte counts aren't worth parsing tqdm output.
        let result = try runProcess(
            executable: QwenAsrSidecar.venvHFCli,
            arguments: ["download", repo, "--quiet"],
            workingDirectory: QwenAsrSidecar.installRoot,
            extraEnv: env,
            onStderrLine: { line in
                if line.lowercased().contains("downloading") {
                    Self.hfFileCount.withLock { $0 += 1 }
                    let count = Self.hfFileCount.withLock { $0 }
                    progress(min(0.9, Double(count) / 8.0))
                }
            }
        )
        Self.hfFileCount.withLock { $0 = 0 }
        guard result.exitStatus == 0 else {
            throw QwenAsrSidecarError.modelDownloadFailed(
                "huggingface-cli download \(repo) exit \(result.exitStatus). Last 4kB of stderr: \(result.stderr.suffix(4096))"
            )
        }
        progress(1.0)
    }

    static func writeManifest() throws {
        let manifest = QwenAsrSidecarManifest(
            schemaVersion: QwenAsrSidecar.bundledSchemaVersion,
            pythonReleaseTag: QwenAsrSidecar.Python.releaseTag,
            pythonVersion: QwenAsrSidecar.Python.cpythonVersion,
            pythonSha256: QwenAsrSidecar.Python.sha256Hex,
            asrModel: QwenAsrSidecar.Models.asrRepo,
            alignerModel: QwenAsrSidecar.Models.alignerRepo,
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: QwenAsrSidecar.manifestFile, options: .atomic)
    }

    // MARK: - Manifest helpers

    static func loadManifest() -> QwenAsrSidecarManifest? {
        guard let data = try? Data(contentsOf: QwenAsrSidecar.manifestFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QwenAsrSidecarManifest.self, from: data)
    }

    /// True when an existing install matches the bundled schema and
    /// all critical files are still on disk. The manager treats a
    /// `false` here as "needs install" even if some files exist.
    static func isInstallUpToDate() -> Bool {
        guard let manifest = loadManifest() else { return false }
        guard manifest.schemaVersion == QwenAsrSidecar.bundledSchemaVersion else { return false }
        let fm = FileManager.default
        let required = [
            QwenAsrSidecar.pythonBin,
            QwenAsrSidecar.venvPython,
            QwenAsrSidecar.serverPy,
        ]
        return required.allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Uninstall

    /// Removes everything: install dir + HF cache. Used by Settings
    /// "Uninstall" button. Best-effort — caller already knows the
    /// sidecar process is stopped.
    static func uninstall() {
        try? FileManager.default.removeItem(at: QwenAsrSidecar.installRoot)
        try? FileManager.default.removeItem(at: QwenAsrSidecar.huggingFaceCache)
    }

    // MARK: - Internals

    private static let pipCollectedCount = OSAllocatedCounter(initial: 0)
    private static let hfFileCount = OSAllocatedCounter(initial: 0)

    private static func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func copyOverwrite(from src: URL, to dst: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

// MARK: - Subprocess utilities

struct SubprocessResult {
    var exitStatus: Int32
    var stdout: String
    var stderr: String
}

/// Runs a subprocess synchronously, capturing stdout+stderr and
/// optionally streaming stderr lines to a callback for progress
/// reporting. Inherits a minimal env (PATH stripped because the
/// bundled python doesn't need any host PATH entries) plus whatever
/// `extraEnv` adds.
@discardableResult
func runProcess(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    extraEnv: [String: String],
    onStderrLine: ((String) -> Void)? = nil
) throws -> SubprocessResult {
    let proc = Process()
    proc.executableURL = executable
    proc.arguments = arguments
    proc.currentDirectoryURL = workingDirectory

    // Start from a sterile env. We propagate HOME (for HF_HOME
    // expansion in pip / hf libs that fall back to it) and a clean
    // /usr/bin:/bin PATH so the subprocess can find /usr/bin/tar etc.
    // if it shells out internally.
    var env: [String: String] = [
        "HOME": NSHomeDirectory(),
        "PATH": "/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        // Apple Silicon MPS occasionally chokes on default fallback;
        // explicitly opt in so torch operations that lack an MPS
        // kernel fall back to CPU instead of crashing.
        "PYTORCH_ENABLE_MPS_FALLBACK": "1",
    ]
    for (k, v) in extraEnv {
        env[k] = v
    }
    proc.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe

    // Drain stdout in the background so a chatty subprocess (pip,
    // huggingface-cli) can't deadlock by filling the OS pipe buffer
    // while we wait on stderr.
    let stdoutLines = LineBuffer { _ in }
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { return }
        stdoutLines.append(chunk)
    }

    let stderrLines = LineBuffer { line in
        onStderrLine?(line)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { return }
        stderrLines.append(chunk)
    }

    try proc.run()
    ActiveSubprocessRegistry.shared.setCurrent(proc)
    defer { ActiveSubprocessRegistry.shared.setCurrent(nil) }
    proc.waitUntilExit()

    // Stop the readabilityHandlers, then drain anything left in the
    // pipes synchronously. The handler may have raced with EOF.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    if let leftover = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil {
        stdoutLines.append(leftover)
    }
    if let leftover = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil {
        stderrLines.append(leftover)
    }

    let outBytes = stdoutLines.flush()
    let errBytes = stderrLines.flush()

    return SubprocessResult(
        exitStatus: proc.terminationStatus,
        stdout: String(data: outBytes, encoding: .utf8) ?? "",
        stderr: String(data: errBytes, encoding: .utf8) ?? ""
    )
}

/// Buffers byte chunks read from a pipe and emits them line-by-line.
/// We can't trust subprocess stderr to be line-flushed cleanly
/// (especially when the process uses `\r` for tqdm) so this strips
/// `\r` carriage returns and splits on `\n` only.
final class LineBuffer: @unchecked Sendable {
    private let handler: (String) -> Void
    private var pending = Data()
    private var captured = Data()
    private let lock = NSLock()

    init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        captured.append(chunk)
        emitLines()
    }

    func flush() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            if let s = String(data: pending, encoding: .utf8) {
                let cleaned = s.replacingOccurrences(of: "\r", with: "")
                if !cleaned.isEmpty { handler(cleaned) }
            }
            pending.removeAll(keepingCapacity: false)
        }
        return captured
    }

    private func emitLines() {
        while let nlIdx = pending.firstIndex(of: 0x0a) {
            let lineData = pending.subdata(in: 0..<nlIdx)
            pending.removeSubrange(0...nlIdx)
            if let s = String(data: lineData, encoding: .utf8) {
                let cleaned = s.replacingOccurrences(of: "\r", with: "")
                if !cleaned.isEmpty { handler(cleaned) }
            }
        }
    }
}

/// Atomically updateable counter used by the installer's stderr-line
/// callbacks. Process() spawns its readability handlers on a private
/// thread, so we need cross-thread protection.
final class OSAllocatedCounter: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()

    init(initial: Int) { self.value = initial }

    @discardableResult
    func withLock<R>(_ body: (inout Int) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Process registry shared by `runProcess`. Lets `applicationWill
/// Terminate` reach in and SIGTERM whatever installer subprocess is
/// currently running (pip / huggingface-cli / tar / venv) so a
/// graceful quit doesn't strand a multi-minute download in the
/// background. Crash-time orphans aren't preventable from here —
/// `server.py` carries its own parent-death watchdog, but pip/hf/tar
/// are third-party processes we don't control. We accept that as a
/// tolerable corner case (idempotent re-install on next launch).
final class ActiveSubprocessRegistry: @unchecked Sendable {
    static let shared = ActiveSubprocessRegistry()
    private var current: Process?
    private let lock = NSLock()

    private init() {}

    func setCurrent(_ proc: Process?) {
        lock.lock()
        defer { lock.unlock() }
        current = proc
    }

    func terminateCurrent() {
        lock.lock()
        let proc = current
        lock.unlock()
        guard let proc, proc.isRunning else { return }
        proc.terminate()
    }
}

/// Forwards URLSession download progress into a 0-1 callback and
/// surfaces completion / failure via a continuation. We can't use
/// the convenience `URLSession.download(from:delegate:)` because per-
/// task delegate delivery of `urlSession(_:downloadTask:didWriteData:
/// ...)` is unreliable across macOS releases — the canonical path
/// is to be the session-level delegate and pump callbacks ourselves.
final class ProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    private var cancelled = false
    var completionContinuation: CheckedContinuation<(URL, URLResponse), Error>?
    private let stateLock = NSLock()

    init(handler: @Sendable @escaping (Double) -> Void) {
        self.handler = handler
    }

    func cancel() { cancelled = true }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard !cancelled, totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        handler(min(1.0, max(0.0, f)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file at `location` is reaped as soon as this method
        // returns, so we have to move it synchronously here. We move
        // it to a sibling tmp path that the caller will then move into
        // its real destination — passing the URL straight back through
        // the continuation would race with that reap.
        let parent = location.deletingLastPathComponent()
        let stable = parent.appendingPathComponent("cutti-py-\(UUID().uuidString).tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
        } catch {
            stateLock.lock()
            let cont = completionContinuation
            completionContinuation = nil
            stateLock.unlock()
            cont?.resume(throwing: error)
            return
        }
        let response = downloadTask.response ?? URLResponse()
        stateLock.lock()
        let cont = completionContinuation
        completionContinuation = nil
        stateLock.unlock()
        cont?.resume(returning: (stable, response))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // didFinishDownloadingTo runs first on success and consumes
        // the continuation; we only resume here on the error path.
        guard let error else { return }
        stateLock.lock()
        let cont = completionContinuation
        completionContinuation = nil
        stateLock.unlock()
        cont?.resume(throwing: error)
    }
}

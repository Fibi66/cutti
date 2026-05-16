import Foundation

/// Namespace + filesystem layout for the Qwen3-ASR sidecar.
///
/// Why a sidecar instead of a Swift-native ONNX path: the on-disk
/// PyTorch + ForcedAligner pipeline is (a) the only path with
/// per-character CJK timestamps that the editor cue builder needs,
/// (b) the official upstream code path so we stay in sync with
/// Qwen3-ASR releases, and (c) faster than the ONNX int4 build at
/// equal accuracy on Apple Silicon. The cost is shipping a private
/// Python interpreter + venv (~6GB total after model download) on
/// disk per user. We do that lazily — no first-launch tax for users
/// who never enable Chinese-first transcription.
enum QwenAsrSidecar {

    /// `1` corresponds to the bundled Resources/QwenAsrSidecar/VERSION
    /// file. Bumped when server.py / requirements.txt / the Python
    /// runtime version changes; the manager forces a reinstall
    /// (or upgrade pass) when manifest.json reports a lower number.
    static let bundledSchemaVersion: Int = 1

    /// Pinned python-build-standalone release. astral-sh signs and
    /// hashes every release; we pin a specific tag + SHA256 so a
    /// compromised mirror or hijacked tag can't ship arbitrary code.
    /// Apple Silicon only — Intel Macs hit the preflight gate before
    /// the installer runs.
    enum Python {
        static let releaseTag = "20260504"
        static let cpythonVersion = "3.12.13"
        static let assetName =
            "cpython-3.12.13+20260504-aarch64-apple-darwin-install_only.tar.gz"
        static let downloadURL = URL(string:
            "https://github.com/astral-sh/python-build-standalone/releases/download/" +
            releaseTag +
            "/cpython-3.12.13%2B20260504-aarch64-apple-darwin-install_only.tar.gz"
        )!
        static let sha256Hex =
            "dac5f4a78c8c921cf7b5aade0c9961b913667f5ece79c7a47d1ebbdb7453e750"
    }

    /// Models we pre-fetch at install time so the first transcription
    /// call doesn't surprise the user with a 5GB download. Keeping
    /// these in code (not config) lets the installer's manifest record
    /// a known-good combination and detect drift on upgrade.
    enum Models {
        static let asrRepo = "Qwen/Qwen3-ASR-1.7B"
        static let alignerRepo = "Qwen/Qwen3-ForcedAligner-0.6B"
    }

    /// Three consecutive boot failures within a single app session
    /// trip the circuit breaker. The setting is not persisted — a
    /// restart re-enables Qwen so a transient OS issue doesn't lock
    /// the user out forever.
    static let bootFailureThreshold = 3
}

extension QwenAsrSidecar {

    /// Resolves the user-Library install root, creating intermediate
    /// directories on demand. Failures here are extremely rare (read-
    /// only home dir → app can't function at all), so we crash with a
    /// clear message rather than thread the error through every call
    /// site.
    static var installRoot: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let dir = appSupport
            .appendingPathComponent("cutti", isDirectory: true)
            .appendingPathComponent("qwen-asr", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// HuggingFace cache dir. We deliberately point HF_HOME inside our
    /// app's cache so `uninstall()` can free the ~6GB of model weights
    /// without the user having to know about ~/.cache/huggingface.
    static var huggingFaceCache: URL {
        let fm = FileManager.default
        let cacheRoot = (try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches")
        let dir = cacheRoot
            .appendingPathComponent("cutti", isDirectory: true)
            .appendingPathComponent("qwen-asr", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var pythonRoot: URL { installRoot.appendingPathComponent("python", isDirectory: true) }
    static var pythonBin: URL { pythonRoot.appendingPathComponent("bin/python3", isDirectory: false) }
    static var venvRoot: URL { installRoot.appendingPathComponent(".venv", isDirectory: true) }
    static var venvPython: URL { venvRoot.appendingPathComponent("bin/python3", isDirectory: false) }
    static var venvHFCli: URL { venvRoot.appendingPathComponent("bin/huggingface-cli", isDirectory: false) }
    static var serverPy: URL { installRoot.appendingPathComponent("server.py", isDirectory: false) }
    static var requirementsTxt: URL { installRoot.appendingPathComponent("requirements.txt", isDirectory: false) }
    static var versionFile: URL { installRoot.appendingPathComponent("VERSION", isDirectory: false) }
    static var manifestFile: URL { installRoot.appendingPathComponent("manifest.json", isDirectory: false) }
    static var portFile: URL { installRoot.appendingPathComponent("port.txt", isDirectory: false) }

    /// SwiftPM-resource-bundle accessor for the payload that ships
    /// inside the .app. We always copy out of `Bundle.module`, never
    /// reference these files directly — the bundle is read-only and
    /// the venv install needs to write into its sibling dirs.
    static var bundledServerPy: URL? {
        Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "QwenAsrSidecar")
    }
    static var bundledRequirementsTxt: URL? {
        Bundle.module.url(forResource: "requirements", withExtension: "txt", subdirectory: "QwenAsrSidecar")
    }
    static var bundledVersionFile: URL? {
        Bundle.module.url(forResource: "VERSION", withExtension: nil, subdirectory: "QwenAsrSidecar")
    }
}

/// Manifest persisted at `installRoot/manifest.json` after a successful
/// install. Used to detect "user upgraded cutti and the bundled
/// schema bumped — must reinstall" without having to crawl the venv.
struct QwenAsrSidecarManifest: Codable, Equatable {
    var schemaVersion: Int
    var pythonReleaseTag: String
    var pythonVersion: String
    var pythonSha256: String
    var asrModel: String
    var alignerModel: String
    var installedAt: Date
}

/// Coarse phases reported by the installer for UI progress. The
/// progress fraction within each phase is best-effort — pip and HF
/// downloads stream incrementally but the absolute totals aren't
/// known up front, so the manager smooths these into an aggregate
/// 0-1 number for the progress bar.
enum QwenAsrInstallPhase: Equatable, Sendable {
    case preflight
    case downloadingPython
    case verifyingPython
    case extractingPython
    case creatingVenv
    case installingPip
    case downloadingAsrModel
    case downloadingAlignerModel
    case finalising

    var displayLabel: String {
        switch self {
        case .preflight: return "Checking system…"
        case .downloadingPython: return "Downloading Python runtime…"
        case .verifyingPython: return "Verifying Python checksum…"
        case .extractingPython: return "Extracting Python runtime…"
        case .creatingVenv: return "Creating virtual environment…"
        case .installingPip: return "Installing PyTorch and dependencies…"
        case .downloadingAsrModel: return "Downloading Qwen3-ASR model (~3.5 GB)…"
        case .downloadingAlignerModel: return "Downloading ForcedAligner model (~1.2 GB)…"
        case .finalising: return "Finalising…"
        }
    }

    /// Approximate share of overall install time, used to map a
    /// per-phase progress (0-1) into an overall progress (0-1).
    /// Tuned from the bench install on an M-series Mac with a
    /// reasonable home internet connection. Approximations are fine —
    /// the bar is a hint, not a contract.
    var overallShare: (start: Double, length: Double) {
        switch self {
        case .preflight:                return (0.00, 0.01)
        case .downloadingPython:        return (0.01, 0.04)
        case .verifyingPython:          return (0.05, 0.01)
        case .extractingPython:         return (0.06, 0.02)
        case .creatingVenv:             return (0.08, 0.02)
        case .installingPip:            return (0.10, 0.30)
        case .downloadingAsrModel:      return (0.40, 0.40)
        case .downloadingAlignerModel:  return (0.80, 0.18)
        case .finalising:               return (0.98, 0.02)
        }
    }
}

enum QwenAsrSidecarError: Error, LocalizedError {
    case requiresAppleSilicon
    case requiresDirectDistribution
    case insufficientFreeSpace(required: Int64, available: Int64)
    case bundledResourcesMissing
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case venvCreationFailed(String)
    case pipInstallFailed(String)
    case modelDownloadFailed(String)
    case sidecarSpawnFailed(String)
    case sidecarBootTimeout
    case authTokenMissing
    case sidecarReturnedError(status: Int, body: String)
    case circuitBreakerOpen
    case notInstalled
    case alreadyInstalling

    var errorDescription: String? {
        switch self {
        case .requiresAppleSilicon:
            return "Qwen3-ASR requires an Apple Silicon Mac. Falling back to other speech engines."
        case .requiresDirectDistribution:
            return "Qwen3-ASR is not available in this build of Cutti."
        case .insufficientFreeSpace(let required, let available):
            return "Need \(byteString(required)) free; only \(byteString(available)) available."
        case .bundledResourcesMissing:
            return "Sidecar payload is missing from this Cutti build. Please reinstall the app."
        case .downloadFailed(let detail):
            return "Download failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Python runtime checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .extractionFailed(let detail):
            return "Could not extract Python runtime: \(detail)"
        case .venvCreationFailed(let detail):
            return "Failed to create the Python virtual environment: \(detail)"
        case .pipInstallFailed(let detail):
            return "Failed to install PyTorch dependencies: \(detail)"
        case .modelDownloadFailed(let detail):
            return "Failed to download the Qwen models: \(detail)"
        case .sidecarSpawnFailed(let detail):
            return "Could not start the local Qwen3-ASR server: \(detail)"
        case .sidecarBootTimeout:
            return "The Qwen3-ASR server did not become ready in time."
        case .authTokenMissing:
            return "Internal error: sidecar auth token is missing."
        case .sidecarReturnedError(let status, let body):
            return "Sidecar HTTP \(status): \(body)"
        case .circuitBreakerOpen:
            return "Qwen3-ASR has failed to start repeatedly this session. Restart Cutti to try again."
        case .notInstalled:
            return "Qwen3-ASR is not installed yet."
        case .alreadyInstalling:
            return "Qwen3-ASR is already being installed."
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

/// Apple Silicon detection. macOS apps built universal will report
/// `arm64` here when running natively under Apple Silicon and `x86_64`
/// when running under Rosetta 2 on Intel Macs. python-build-standalone
/// only ships an aarch64 macOS tarball at the URL we pinned, so we
/// reject Intel up front instead of letting the SHA fail mid-install.
func qwenAsrHostIsAppleSilicon() -> Bool {
    var info = utsname()
    uname(&info)
    let machine = withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
    return machine == "arm64"
}

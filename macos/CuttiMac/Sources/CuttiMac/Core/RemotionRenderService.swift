import Foundation

/// Remotion overlay rendering — the Swift-side counterpart to the
/// `remotion/` project at the repo root.
///
/// The overall flow Cutti uses for AI-generated overlays is:
///
///   1. User selects a primary segment + writes a prompt.
///   2. LLM picks a `templateID` (e.g. `"ChapterTitle"`) and produces a
///      JSON blob that satisfies that template's zod schema.
///   3. This renderer produces a transparent ProRes 4444 `.mov` at the
///      requested duration.
///   4. The caller imports that file through the normal media pipeline
///      and drops it onto the overlay track via `insertBRollOverlay`.
///
/// The renderer is split behind `RemotionOverlayRendering` so the
/// Mac app can swap between a local dev renderer (shelling out to the
/// checked-in `remotion/` project) and a future cloud render service
/// without touching the ViewModel.

// MARK: - Request

struct RemotionRenderRequest: Sendable, Equatable {
    /// Composition ID — matches what `remotion/src/Root.tsx` registers
    /// (e.g. `"ChapterTitle"`). Case-sensitive.
    var templateID: String

    /// Already-encoded JSON string validated against the template's
    /// zod schema. We keep this as a string (not `[String: Any]`) so
    /// the type stays `Sendable`/`Equatable` and so the caller owns
    /// schema conformance — this renderer is intentionally dumb.
    var propsJSON: String

    /// Output duration in seconds. Used to size the Remotion composition
    /// via its `calculateMetadata` hook, and later by the consumer
    /// (`insertBRollOverlay`) to size the overlay segment.
    var durationSeconds: Double

    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30

    /// Per-feature attribution forwarded to the relay so the admin
    /// dashboard can split AI-driven animation renders from any
    /// future manual / template-picker renders. Defaults to
    /// `"animation"` because every render call site today is downstream
    /// of an AI `generate_overlay` tool call.
    ///
    /// Only consumed by `CloudRemotionRenderer`; `LocalRemotionRenderer`
    /// (dev build, no metering) ignores it.
    var task: String? = "animation"
}

// MARK: - Errors

enum RemotionRenderError: Error, LocalizedError, Equatable {
    case projectDirectoryMissing(URL)
    case renderFailed(exitCode: Int32, stderr: String)
    case launchFailed(String)
    /// Pre-localized, user-safe message coming from the cloud relay
    /// (e.g. quota exhausted, email not verified, sign-in required).
    /// Shown verbatim — callers must NOT stuff raw HTTP bodies in here.
    case relayMessage(String)

    var errorDescription: String? {
        switch self {
        case .projectDirectoryMissing(let url):
            return "Remotion project not found at \(url.path)"
        case .renderFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Remotion render failed (exit \(code)): \(trimmed)"
        case .launchFailed(let message):
            return "Remotion render could not launch: \(message)"
        case .relayMessage(let message):
            return message
        }
    }
}

// MARK: - Protocol

protocol RemotionOverlayRendering: Sendable {
    /// Render `request` and write the resulting transparent ProRes 4444
    /// `.mov` to `outputURL`. Callers are responsible for choosing a
    /// unique output path — typically inside the project's scratch
    /// directory so the file survives long enough for the importer
    /// to fingerprint + transcode it.
    func render(_ request: RemotionRenderRequest, outputURL: URL) async throws
}

// MARK: - Local implementation

struct LocalRemotionRenderer: RemotionOverlayRendering {
    /// Absolute path to the `remotion/` directory that ships with the
    /// repository. `npm install` must have been run there at least once.
    let projectDirectory: URL

    /// Best-effort resolver for the checked-in `remotion/` project
    /// directory. Order of precedence:
    ///   1. `$CUTTI_REMOTION_DIR` — explicit override for CI / packaged
    ///      builds where the project sits outside the source tree.
    ///   2. A walk up from `#filePath` to the repo root + `remotion`.
    ///      This works for dev builds (`swift run`, Xcode) because the
    ///      source file path is baked in at compile time.
    ///
    /// Returns the resolved URL regardless of whether it exists — callers
    /// (and `render(_:outputURL:)`) are responsible for surfacing a
    /// friendly error when the directory is missing so the failure shows
    /// up as a banner rather than a silent no-op.
    static func defaultProjectDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CUTTI_REMOTION_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // #filePath ≈ .../cutti/macos/CuttiMac/Sources/CuttiMac/Core/RemotionRenderService.swift
        // Drop 6 components (filename + Core + CuttiMac + Sources + CuttiMac + macos) → repo root.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("remotion", isDirectory: true)
    }

    /// Launch `npx` via `/usr/bin/env` so we inherit the user's shell
    /// PATH (matches `FFmpegProxyFallback`'s pattern). Override for tests.
    var envExecutable: URL = URL(fileURLWithPath: "/usr/bin/env")

    /// Arg list handed to `/usr/bin/env`. ProRes 4444 is forced here
    /// (rather than relying on `remotion.config.ts`) so external callers
    /// can trust the output has an alpha channel even if the config
    /// drifts. The overlay track refuses to composite without alpha.
    static func makeArguments(request: RemotionRenderRequest, outputURL: URL) -> [String] {
        [
            "npx", "remotion", "render",
            request.templateID,
            outputURL.path,
            "--codec=prores",
            "--prores-profile=4444",
            "--props=\(request.propsJSON)",
        ]
    }

    func render(_ request: RemotionRenderRequest, outputURL: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectDirectory.path) else {
            throw RemotionRenderError.projectDirectoryMissing(projectDirectory)
        }
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = envExecutable
        process.arguments = Self.makeArguments(request: request, outputURL: outputURL)
        process.currentDirectoryURL = projectDirectory

        let errPipe = Pipe()
        process.standardError = errPipe
        // Suppress stdout — the render progress lines would flood the
        // Xcode console. We only need stderr on failure.
        process.standardOutput = Pipe()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderr = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: RemotionRenderError.renderFailed(
                        exitCode: finished.terminationStatus,
                        stderr: stderr
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: RemotionRenderError.launchFailed(
                    error.localizedDescription
                ))
            }
        }
    }
}

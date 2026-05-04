import Foundation
import CuttiKit

/// Assembles the Phase 1 Apple Silicon app stack.
///
/// This is the single authoritative factory for the Phase 1 component graph.
/// All components are wired here, keeping the app entry point free of
/// construction details.
///
/// - `runtimeArchitecture`: Describes the current CPU runtime so callers can
///   surface a warning when running outside native arm64.
/// - `proxyProfile`: The proxy encoding target for this stack (always
///   `.appleSiliconEditingProxy` for Phase 1).
/// - `store`: Project-scoped file I/O.
/// - `mediaCore`: Import, transcode, and source-validation logic.
/// - `playbackCore`: Proxy-only AVPlayer factory with asset caching.
struct AppleSiliconPhaseOneStack {
    let runtimeArchitecture: RuntimeArchitecture
    let proxyProfile: ProxyProfile
    let store: ProjectStore
    let mediaCore: MediaCore
    let playbackCore: AVPlaybackCore
    let analysisPipeline: FullAnalysisPipeline

    // MARK: - Factory

    /// Builds the Phase 1 stack for the given project root.
    ///
    /// This factory owns the full construction sequence, including the project
    /// bootstrap step (creating the `media/` and `logs/` subdirectory layout
    /// and an initial manifest if one does not yet exist).  Callers receive a
    /// fully ready-to-use stack or a thrown error — they must not call
    /// `store.bootstrapProject()` separately.
    ///
    /// - Parameters:
    ///   - projectRoot: The directory that contains (or will contain) the
    ///     project's `media/` and `logs/` subdirectories.
    ///   - runtimeArchitecture: The CPU runtime descriptor. Defaults to the
    ///     live sysctlbyname reading. Pass a synthetic value in tests.
    /// - Throws: Any `FileManager` error raised while creating the required
    ///   project directories or writing the initial manifest.
    /// - Returns: A fully-assembled `AppleSiliconPhaseOneStack`.
    static func make(
        projectRoot: URL,
        runtimeArchitecture: RuntimeArchitecture = .current()
    ) throws -> AppleSiliconPhaseOneStack {
        let proxyProfile = ProxyProfile.appleSiliconEditingProxy
        let store = ProjectStore(projectRoot: projectRoot)
        try store.bootstrapProject()
        // Production wiring includes the gates so concurrent imports
        // don't race on manifest writes and don't saturate Media Engine.
        // Limit=2 covers Apple Silicon's 1–2 Media Engine SoCs while
        // still letting one I/O-heavy import overlap with one
        // encode-heavy one.
        let manifestGate = ManifestMutationGate(store: store)
        let concurrencyGate = ImportConcurrencyGate(limit: 2)
        let mediaCore = MediaCore(
            store: store,
            analyzer: AVAssetAnalyzer(),
            primaryTranscoder: AVProxyTranscoder(),
            fallbackTranscoder: FFmpegProxyFallback(),
            manifestGate: manifestGate,
            concurrencyGate: concurrencyGate
        )
        let playbackCore = AVPlaybackCore()
        let analysisPipeline = FullAnalysisPipeline()

        return AppleSiliconPhaseOneStack(
            runtimeArchitecture: runtimeArchitecture,
            proxyProfile: proxyProfile,
            store: store,
            mediaCore: mediaCore,
            playbackCore: playbackCore,
            analysisPipeline: analysisPipeline
        )
    }

    // MARK: - View Model

    /// Creates the `MediaCoreViewModel` wired to this stack's components.
    ///
    /// Must be called on the `@MainActor` because `MediaCoreViewModel` is
    /// main-actor-bound.
    @MainActor
    func makeViewModel() -> MediaCoreViewModel {
        MediaCoreViewModel(
            playbackCore: playbackCore,
            mediaCore: mediaCore,
            store: store,
            projectRoot: store.projectRoot,
            analysisPipeline: analysisPipeline,
            overlayRenderer: Self.makeDefaultOverlayRenderer()
        )
    }

    /// Prefer the relay-backed `CloudRemotionRenderer` when we have
    /// credentials; otherwise fall back to the local dev renderer that
    /// shells out to `npx remotion render`. Returns `nil` for BYOK
    /// users — they opted out of the Cutti subscription stack, which
    /// includes the cloud Remotion renderer (the proprietary skill +
    /// Azure Container Apps render farm). When the result is `nil`,
    /// `MediaCoreViewModel.makeOverlayCache()` surfaces the BYOK
    /// limitation banner instead of generating an animation.
    ///
    /// Shared by both the dashboard project entry path
    /// (`AppleSiliconPhaseOneStack.makeViewModel`) and the standalone
    /// `ContentView` initializer so any project-opening route gets the
    /// same provider-aware behaviour.
    ///
    /// The closures default to live readers but exist so unit tests can
    /// pin all three inputs without mutating `UserDefaults.standard` /
    /// the keychain.
    @MainActor
    static func makeDefaultOverlayRenderer(
        aiProvider: () -> AIProviderPreference = { CuttiSettings.aiProvider() },
        bearerToken: () -> String? = { RelaySession.currentBearerToken() },
        devToken: () -> String? = {
            UserDefaults.standard.string(forKey: "cutti_relay_dev_token")
        }
    ) -> (any RemotionOverlayRendering)? {
        // BYOK opted out of every backend dependency, including the
        // cloud overlay renderer. A stale JWT from a previous
        // subscription must NOT silently keep routing renders through
        // `api.cutti.app`. The local dev renderer is also unreachable
        // from a packaged `.app` (it walks `#filePath` to the repo's
        // `remotion/` directory), so returning `nil` is the correct
        // honest answer for BYOK — the caller will show the
        // "Cutti Cloud only" banner.
        if aiProvider() == .custom {
            print("🎬 [overlay] makeDefaultOverlayRenderer: aiProvider=.custom → nil (BYOK has no overlay renderer)")
            return nil
        }
        let url = URL(string: RelayClient.relayBaseURL)!
        let jwt = bearerToken() ?? ""
        let dev = devToken() ?? ""
        let token: String
        if !jwt.isEmpty {
            token = "jwt:\(jwt)"
        } else if !dev.isEmpty {
            token = "dev:\(dev)"
        } else {
            token = ""
        }
        if !token.isEmpty {
            print("🎬 [overlay] makeDefaultOverlayRenderer: CloudRemotionRenderer relay=\(url.absoluteString) tokenKind=\(jwt.isEmpty ? "dev" : "jwt")")
            return CloudRemotionRenderer(relayBaseURL: url, bearerToken: token)
        }
        print("🎬 [overlay] makeDefaultOverlayRenderer: NO token (jwt empty, dev empty) → falling back to LocalRemotionRenderer (only works in dev `swift run`, not packaged .app)")
        return LocalRemotionRenderer(
            projectDirectory: LocalRemotionRenderer.defaultProjectDirectory()
        )
    }
}

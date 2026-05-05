import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

/// Thin SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Why this class exists:
/// - Sparkle's controller is AppKit-flavored (KVO-observable, NSObject).
///   This wrapper republishes the one piece of state the Settings UI cares
///   about (`canCheckForUpdates`) as a `@Published` property so a SwiftUI
///   `Button` can be enabled/disabled idiomatically.
/// - The controller MUST live for the lifetime of the app (Sparkle wires
///   itself into the run-loop and listens for "did become active" events
///   to schedule background checks). We pin it to a singleton so nothing
///   accidentally tears it down on view churn.
/// - On Mac App Store builds, Apple forbids bundling third-party
///   updaters — auto-update is the Store's job. We detect that at runtime
///   and don't instantiate Sparkle at all in that distribution path.
///   Direct-download builds (Developer ID `.dmg` from GitHub Releases)
///   are the only path where Sparkle runs.
///
/// User-facing toggles (auto-check, auto-download) are bound directly via
/// `@AppStorage` to the UserDefaults keys Sparkle reads internally
/// (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`). That avoids
/// having to mirror state through this wrapper and means the OS is the
/// single source of truth.
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    /// Underlying Sparkle controller. `nil` on Mac App Store builds.
    private let controller: SPUStandardUpdaterController?

    /// Mirrors `controller.updater.canCheckForUpdates`. Defaults to
    /// `false` when Sparkle is disabled (App Store path) so the
    /// "Check Now" button stays disabled.
    @Published private(set) var canCheckForUpdates: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    /// True when Sparkle is wired up and the Updates UI should be shown.
    var isEnabled: Bool { controller != nil }

    private init() {
        switch CuttiDistribution.current {
        case .appStore:
            // Mac App Store path: never bundle a third-party updater.
            // Apple's review guidelines forbid it and the Store handles
            // updates itself.
            self.controller = nil
        case .direct:
            // Defensive: if the bundle is missing or has an empty
            // `SUPublicEDKey`, Sparkle's `start()` shows a fatal alert
            // ("The updater failed to start" / "The provided EdDSA key
            // could not be decoded") on every launch. That happens when
            // a contributor packages a local Cutti.app without exporting
            // SPARKLE_PUBLIC_ED_KEY before running scripts/package-macos.sh.
            // Skip Sparkle entirely in that case — the Updates UI will
            // hide itself just like on the App Store path.
            let edKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey")
                as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if edKey.isEmpty {
                NSLog(
                    "[Cutti] SUPublicEDKey is missing or empty in Info.plist — disabling Sparkle. "
                    + "Set SPARKLE_PUBLIC_ED_KEY before running scripts/package-macos.sh to enable in-app updates."
                )
                self.controller = nil
            } else {
                self.controller = SPUStandardUpdaterController(
                    startingUpdater: true,
                    updaterDelegate: nil,
                    userDriverDelegate: nil
                )
            }
        }

        if let updater = controller?.updater {
            // Republish KVO-driven state as @Published. Combine's
            // `publisher(for:)` keeps us off raw NSObject KVO ceremony.
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    self?.canCheckForUpdates = value
                }
                .store(in: &cancellables)
        }
    }

    /// Triggers Sparkle's user-driven check. Sparkle handles the entire
    /// flow from here: shows its own progress sheet, downloads the
    /// signed update, validates the EdDSA signature, prompts the user
    /// to install + relaunch.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// `nil` until Sparkle has performed at least one check. Read from
    /// the same UserDefaults key Sparkle writes internally.
    var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }
}

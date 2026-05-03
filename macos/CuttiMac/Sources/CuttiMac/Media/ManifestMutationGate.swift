import Foundation
import CuttiKit

/// Serialises read-modify-write of `MediaManifest` on disk. Without this,
/// two concurrent `importLocalVideo` calls would each `loadManifest()`,
/// mutate locally, and `saveManifest()` — and the second writer would
/// silently clobber the first's append.
actor ManifestMutationGate {
    private let store: ProjectStore

    init(store: ProjectStore) {
        self.store = store
    }

    /// Atomically loads the manifest, applies `body`, and persists the
    /// result. The closure runs serially with respect to all other gate
    /// users so concurrent imports cannot lose records.
    @discardableResult
    func mutate<T: Sendable>(
        _ body: (inout MediaManifest) throws -> T
    ) throws -> T {
        var manifest = try store.loadManifest()
        let result = try body(&manifest)
        try store.saveManifest(manifest)
        return result
    }

    /// Read-only snapshot. Useful for the disk-space precheck that needs
    /// to query state without mutating it but still wants to serialise
    /// against in-flight mutations.
    func read<T: Sendable>(
        _ body: (MediaManifest) throws -> T
    ) throws -> T {
        let manifest = try store.loadManifest()
        return try body(manifest)
    }
}

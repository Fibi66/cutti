import Foundation

/// Metadata for a single project, persisted in the app-level registry.
/// Dashboard stats (mediaCount, duration, thumbnail) are NOT stored here —
/// they are derived from each project's manifest on dashboard load.
public struct ProjectInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var lastOpenedAt: Date
    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        lastOpenedAt: Date
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

}

/// Manages the list of projects and their on-disk directories.
///
/// Projects live at `<appSupport>/Cutti/projects/<UUID>/`, each with its
/// own `media/manifest.json` and subdirectories (same layout as ProjectStore).
/// The registry itself is persisted at `<appSupport>/Cutti/projects.json`.
@MainActor
public final class ProjectRegistry: ObservableObject {
    @Published public var projects: [ProjectInfo] = []

    private let baseDirectory: URL
    private let registryURL: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.registryURL = baseDirectory.appending(path: "projects.json")
    }

    // MARK: - Directory helpers

    public func projectRoot(for id: UUID) -> URL {
        baseDirectory.appending(path: "projects/\(id.uuidString)")
    }

    private var projectsDirectory: URL {
        baseDirectory.appending(path: "projects")
    }

    // MARK: - CRUD

    public func createProject(name: String) throws -> ProjectInfo {
        let info = ProjectInfo(
            id: UUID(),
            name: name.isEmpty ? "Untitled Project" : name,
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        // Bootstrap project directory
        let root = projectRoot(for: info.id)
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        projects.append(info)
        try save()
        return info
    }

    public func deleteProject(id: UUID) throws {
        let root = projectRoot(for: id)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        projects.removeAll { $0.id == id }
        try save()
    }

    public func renameProject(id: UUID, newName: String) throws {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = newName
        try save()
    }

    public func updateLastOpened(id: UUID) throws {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].lastOpenedAt = Date()
        try save()
    }

    // MARK: - Persistence

    public func loadAll() throws {
        try FileManager.default.createDirectory(
            at: projectsDirectory,
            withIntermediateDirectories: true
        )

        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            projects = []
            return
        }

        let data = try Data(contentsOf: registryURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = try decoder.decode([ProjectInfo].self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(projects)
        try data.write(to: registryURL, options: .atomic)
    }

    // MARK: - Legacy Migration

    /// Migrates the legacy single-project data (media/, logs/ at app root)
    /// into a new project entry under projects/<UUID>/.
    public func migrateLegacyIfNeeded() throws {
        let legacyManifest = baseDirectory.appending(path: "media/manifest.json")
        guard FileManager.default.fileExists(atPath: legacyManifest.path) else { return }

        // Don't migrate if we already have projects
        if !projects.isEmpty { return }

        let newID = UUID()
        let dest = projectRoot(for: newID)

        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true
        )

        // Move media/ and logs/ into the new project folder
        let legacyMedia = baseDirectory.appending(path: "media")
        let legacyLogs = baseDirectory.appending(path: "logs")

        try FileManager.default.moveItem(
            at: legacyMedia,
            to: dest.appending(path: "media")
        )
        if FileManager.default.fileExists(atPath: legacyLogs.path) {
            try FileManager.default.moveItem(
                at: legacyLogs,
                to: dest.appending(path: "logs")
            )
        }

        let info = ProjectInfo(
            id: newID,
            name: "My Project",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        projects.append(info)
        try save()
    }

    // MARK: - Dashboard Stats (derived from manifest, not cached)

    public struct ProjectStats {
        public let mediaCount: Int
        public let totalDurationSeconds: Double
        public let firstProxyRelativePath: String?
        public init(mediaCount: Int, totalDurationSeconds: Double, firstProxyRelativePath: String?) {
            self.mediaCount = mediaCount
            self.totalDurationSeconds = totalDurationSeconds
            self.firstProxyRelativePath = firstProxyRelativePath
        }
    }

    public func loadStats(for id: UUID) -> ProjectStats {
        let root = projectRoot(for: id)
        let store = ProjectStore(projectRoot: root)
        guard let manifest = try? store.loadManifest() else {
            return ProjectStats(mediaCount: 0, totalDurationSeconds: 0, firstProxyRelativePath: nil)
        }

        let count = manifest.media.count
        let duration = manifest.media.compactMap { $0.analysis?.durationSeconds }.reduce(0, +)
        let firstProxy = manifest.media.first(where: { $0.status == .ready })?.derived.proxyRelativePath
        return ProjectStats(
            mediaCount: count,
            totalDurationSeconds: duration,
            firstProxyRelativePath: firstProxy
        )
    }
}

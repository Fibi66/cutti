import XCTest
import CuttiKit
@testable import CuttiMac

@MainActor
final class ProjectRegistryTests: XCTestCase {
    private func makeRegistry() throws -> (ProjectRegistry, TemporaryDirectory) {
        let temp = try TemporaryDirectory()
        let registry = ProjectRegistry(baseDirectory: temp.url)
        try registry.loadAll()
        return (registry, temp)
    }

    // MARK: - Create

    func test_createProject_addsToListAndCreatesDirectory() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "Test Project")

        XCTAssertEqual(registry.projects.count, 1)
        XCTAssertEqual(project.name, "Test Project")

        // Project directory should exist with manifest
        let root = registry.projectRoot(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "media/manifest.json").path
        ))
    }

    func test_createProject_emptyName_defaultsToUntitled() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "")
        XCTAssertEqual(project.name, "Untitled Project")
    }

    // MARK: - Delete

    func test_deleteProject_removesFromListAndDeletesDirectory() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "To Delete")
        let root = registry.projectRoot(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        try registry.deleteProject(id: project.id)

        XCTAssertTrue(registry.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Rename

    func test_renameProject_updatesName() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "Old Name")
        try registry.renameProject(id: project.id, newName: "New Name")

        XCTAssertEqual(registry.projects[0].name, "New Name")
    }

    // MARK: - Persistence

    func test_persistence_survivesSaveAndReload() throws {
        let (registry, temp) = try makeRegistry()

        let p1 = try registry.createProject(name: "Project A")
        _ = try registry.createProject(name: "Project B")

        // Create a new registry pointing to the same directory
        let registry2 = ProjectRegistry(baseDirectory: temp.url)
        try registry2.loadAll()

        XCTAssertEqual(registry2.projects.count, 2)
        XCTAssertEqual(registry2.projects.first?.id, p1.id)
    }

    // MARK: - Stats

    func test_loadStats_returnsZeroForEmptyProject() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "Empty")
        let stats = registry.loadStats(for: project.id)

        XCTAssertEqual(stats.mediaCount, 0)
        XCTAssertEqual(stats.totalDurationSeconds, 0)
        XCTAssertNil(stats.firstProxyRelativePath)
    }

    func test_loadStats_readsFromManifest() throws {
        let (registry, _) = try makeRegistry()

        let project = try registry.createProject(name: "With Media")
        let root = registry.projectRoot(for: project.id)
        let store = ProjectStore(projectRoot: root)

        // Add a fake media record
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/test.mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 30, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/test.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)

        let stats = registry.loadStats(for: project.id)
        XCTAssertEqual(stats.mediaCount, 1)
        XCTAssertEqual(stats.totalDurationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(stats.firstProxyRelativePath, "media/proxies/test.mov")
    }

    // MARK: - Legacy Migration

    func test_migrateLegacyIfNeeded_movesExistingData() throws {
        let temp = try TemporaryDirectory()
        let baseDir = temp.url

        // Simulate legacy layout: media/ and logs/ directly in app root
        try FileManager.default.createDirectory(
            at: baseDir.appending(path: "media/proxies"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: baseDir.appending(path: "logs"),
            withIntermediateDirectories: true
        )
        // Write a manifest
        let manifestData = "{\"media\": []}".data(using: .utf8)!
        try manifestData.write(to: baseDir.appending(path: "media/manifest.json"))

        let registry = ProjectRegistry(baseDirectory: baseDir)
        try registry.loadAll()
        try registry.migrateLegacyIfNeeded()

        // Should have created one project
        XCTAssertEqual(registry.projects.count, 1)
        XCTAssertEqual(registry.projects[0].name, "My Project")

        // Legacy directories should be moved
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: baseDir.appending(path: "media").path
        ))

        // New project directory should have the data
        let newRoot = registry.projectRoot(for: registry.projects[0].id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: newRoot.appending(path: "media/manifest.json").path
        ))
    }

    func test_migrateLegacyIfNeeded_skipsWhenProjectsExist() throws {
        let temp = try TemporaryDirectory()
        let baseDir = temp.url

        // Create legacy layout
        try FileManager.default.createDirectory(
            at: baseDir.appending(path: "media"),
            withIntermediateDirectories: true
        )
        try "{\"media\": []}".data(using: .utf8)!
            .write(to: baseDir.appending(path: "media/manifest.json"))

        let registry = ProjectRegistry(baseDirectory: baseDir)
        try registry.loadAll()

        // Create a project first
        _ = try registry.createProject(name: "Existing")

        // Migration should skip because projects already exist
        try registry.migrateLegacyIfNeeded()

        XCTAssertEqual(registry.projects.count, 1)
        XCTAssertEqual(registry.projects[0].name, "Existing")

        // Legacy dir should still be there (not moved)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: baseDir.appending(path: "media").path
        ))
    }
}

import Foundation

public struct ProjectStore: Sendable {
    public let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    public var manifestURL: URL {
        projectRoot.appending(path: "media/manifest.json")
    }

    public func bootstrapProject(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: projectRoot.appending(path: "media/proxies"), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: projectRoot.appending(path: "media/thumbnails"), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: projectRoot.appending(path: "media/waveforms"), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: projectRoot.appending(path: "logs"), withIntermediateDirectories: true, attributes: nil)

        if !fileManager.fileExists(atPath: manifestURL.path) {
            try saveManifest(.init())
        }
    }

    public func loadManifest() throws -> MediaManifest {
        let fm = FileManager.default
        // If the manifest doesn't exist yet but the project directory does,
        // return an empty manifest (first launch after DB clear).
        guard fm.fileExists(atPath: manifestURL.path) else {
            // Only gracefully handle missing file when the parent dir exists
            // (i.e. project was bootstrapped). If even the project dir doesn't
            // exist, throw so callers can surface the error.
            let parentDir = manifestURL.deletingLastPathComponent().path
            if fm.fileExists(atPath: parentDir) {
                return MediaManifest()
            }
            throw CocoaError(.fileReadNoSuchFile, userInfo: [
                NSFilePathErrorKey: manifestURL.path
            ])
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MediaManifest.self, from: data)
    }

    public func saveManifest(_ manifest: MediaManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func proxyURL(
        for mediaId: UUID,
        profile: ProxyProfile = .appleSiliconEditingProxy
    ) -> URL {
        projectRoot.appending(path: profile.relativeProxyPath(for: mediaId))
    }

    public func logURL(for mediaId: UUID) -> URL {
        projectRoot.appending(path: "logs/\(mediaId.uuidString).log")
    }
}

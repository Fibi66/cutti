import Foundation

enum AppEnvironment {
    static func makeDefaultProjectRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("cutti", isDirectory: true)
    }
}

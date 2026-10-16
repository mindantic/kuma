import Foundation

enum ResourceLocator {
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var repoRoot: URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? ""),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("x"),
        ]
        for start in candidates {
            var dir = start.deletingLastPathComponent()
            while dir.path != "/" {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    return dir
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    static var resourcesRoot: URL? {
        if isBundled { return Bundle.main.resourceURL }
        return repoRoot
    }

    static func asset(_ name: String) -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent(name)
        let repo = repoRoot?.appendingPathComponent("Assets").appendingPathComponent(name)
        return [bundled, repo].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var voiceDirectory: URL? { folder(bundled: "voice", repo: "Resources/voice") }

    static var integrationsDirectory: URL? { folder(bundled: "Integrations", repo: "Integrations") }

    static var hookBinary: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kuma-hook")
        if isBundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent().appendingPathComponent("kuma-hook")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private static func folder(bundled: String, repo: String) -> URL? {
        let candidates = [
            isBundled ? Bundle.main.resourceURL?.appendingPathComponent(bundled) : nil,
            repoRoot?.appendingPathComponent(repo),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

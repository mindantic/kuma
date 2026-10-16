import Foundation

public final class ProjectNamer: @unchecked Sendable {
    public static let shared = ProjectNamer()

    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init() {}

    public func name(forCwd cwd: String) -> String {
        lock.lock()
        if let hit = cache[cwd] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let value = Self.resolve(cwd: cwd)
        lock.lock()
        cache[cwd] = value
        lock.unlock()
        return value
    }

    public static func resolve(cwd: String) -> String {
        let fallback = folderName(cwd)
        guard !cwd.isEmpty else { return fallback }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if let config = configURL(dotGit: dotGit, isDirectory: isDir.boolValue),
                   let text = try? String(contentsOf: config, encoding: .utf8),
                   let url = originURL(inConfig: text),
                   let repo = repoName(fromRemote: url) {
                    return repo
                }
                return fallback
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { break }
            dir = parent
        }
        return fallback
    }

    static func folderName(_ cwd: String) -> String {
        let base = URL(fileURLWithPath: cwd).lastPathComponent
        return base.isEmpty || base == "/" ? "unknown" : base
    }

    static func configURL(dotGit: URL, isDirectory: Bool) -> URL? {
        if isDirectory { return dotGit.appendingPathComponent("config") }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : dotGit.deletingLastPathComponent().appendingPathComponent(raw)
        let commondir = gitDir.appendingPathComponent("commondir")
        if let c = try? String(contentsOf: commondir, encoding: .utf8) {
            let rel = c.trimmingCharacters(in: .whitespacesAndNewlines)
            let common = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : gitDir.appendingPathComponent(rel)
            return common.standardizedFileURL.appendingPathComponent("config")
        }
        let comps = gitDir.standardizedFileURL.pathComponents
        if let idx = comps.lastIndex(of: "worktrees"), idx > 0 {
            let common = NSString.path(withComponents: Array(comps[..<idx]))
            return URL(fileURLWithPath: common).appendingPathComponent("config")
        }
        return gitDir.appendingPathComponent("config")
    }

    static func originURL(inConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let compact = line.replacingOccurrences(of: " ", with: "")
                inOrigin = compact == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "url" else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func repoName(fromRemote url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let separators = CharacterSet(charactersIn: "/:")
        guard let last = s.components(separatedBy: separators).last, !last.isEmpty else { return nil }
        return last
    }
}

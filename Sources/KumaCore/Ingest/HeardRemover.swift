import Foundation

public struct HeardRemover: Sendable {
    public var claudeSettings: URL
    public var codexHooks: URL
    public var heardHome: URL

    public static let backupSuffix = ".kuma-heard-backup"
    static let markers = ["heard-hook", "/.heard/", "Heard.app/"]

    public init(claudeSettings: URL? = nil, codexHooks: URL? = nil, heardHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeSettings = claudeSettings ?? home.appendingPathComponent(".claude/settings.json")
        self.codexHooks = codexHooks ?? home.appendingPathComponent(".codex/hooks.json")
        self.heardHome = heardHome ?? home.appendingPathComponent(".heard", isDirectory: true)
    }

    public var isHeardPresent: Bool { !plan().isEmpty }

    public func plan() -> [String] {
        (try? compute().changes) ?? []
    }

    @discardableResult
    public func apply() throws -> [String] {
        let result = try compute()
        let fm = FileManager.default
        if let claude = result.claude {
            backup(claudeSettings)
            try JSONFileIO.write(claude, to: claudeSettings)
        }
        if let codex = result.codex, fm.fileExists(atPath: codexHooks.path) {
            backup(codexHooks)
            try JSONFileIO.write(codex, to: codexHooks)
        }
        return result.changes
    }

    static func isHeard(_ handler: OrderedJSON) -> Bool {
        guard let cmd = handler["command"]?.stringValue else { return false }
        return markers.contains { cmd.contains($0) }
    }

    private struct Computation {
        var claude: OrderedJSON?
        var codex: OrderedJSON?
        var changes: [String] = []
    }

    private func compute() throws -> Computation {
        var result = Computation()
        if var root = try JSONFileIO.read(claudeSettings) {
            let original = root
            let removed = HookInstaller.stripNested(&root, where: HeardRemover.isHeard)
            result.changes += removed.map { "Claude: remove hook \($0)" }
            if let line = root["statusLine"], let cmd = line["command"]?.stringValue, HeardRemover.markers.contains(where: { cmd.contains($0) }) {
                if let restored = originalStatusLine(wrapper: cmd, current: line) {
                    root["statusLine"] = restored
                    result.changes.append("Claude: restore statusLine to \(restored["command"]?.stringValue ?? "")")
                } else {
                    root["statusLine"] = nil
                    result.changes.append("Claude: remove Heard statusLine (original command not found)")
                }
            }
            if root != original { result.claude = root }
        }
        if var root = try JSONFileIO.read(codexHooks) {
            let original = root
            let removed = HookInstaller.stripNested(&root, where: HeardRemover.isHeard)
            result.changes += removed.map { "Codex: remove hook \($0)" }
            if root != original { result.codex = root }
        }
        return result
    }

    func originalStatusLine(wrapper: String, current: OrderedJSON) -> OrderedJSON? {
        if let fromBackup = statusLineFromBackups() { return fromBackup }
        guard let cmd = commandFromWrapperScript(wrapper) else { return nil }
        var restored = current
        restored["command"] = .string(cmd)
        if restored["type"] == nil { restored["type"] = .string("command") }
        return restored
    }

    func statusLineFromBackups() -> OrderedJSON? {
        let dir = claudeSettings.deletingLastPathComponent()
        let base = claudeSettings.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix(base + ".heard") && !$0.hasSuffix(".lock") }
            .sorted()
        for name in candidates {
            guard let root = try? JSONFileIO.read(dir.appendingPathComponent(name)),
                  let line = root["statusLine"],
                  let cmd = line["command"]?.stringValue,
                  !HeardRemover.markers.contains(where: { cmd.contains($0) })
            else { continue }
            return line
        }
        return nil
    }

    func commandFromWrapperScript(_ wrapper: String) -> String? {
        var path = wrapper.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\""), let end = path.dropFirst().firstIndex(of: "\"") {
            path = String(path[path.index(after: path.startIndex)..<end])
        } else if let space = path.firstIndex(of: " ") {
            path = String(path[..<space])
        }
        path = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) {
            path = heardHome.appendingPathComponent((path as NSString).lastPathComponent).path
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("printf"), line.contains("$input"), let pipe = line.range(of: "| ") else { continue }
            let cmd = line[pipe.upperBound...].trimmingCharacters(in: .whitespaces)
            if cmd.isEmpty || cmd.contains("heard-hook") || cmd.contains("\"$H\"") { continue }
            return cmd
        }
        return nil
    }

    private func backup(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let target = URL(fileURLWithPath: url.path + HeardRemover.backupSuffix + "-" + stamp)
        try? fm.copyItem(at: url, to: target)
    }
}

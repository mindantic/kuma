import Foundation

public final class ToolLocator: @unchecked Sendable {
    public static let shared = ToolLocator()

    public static let binaryNames: [Tool: [String]] = [
        .claude: ["claude"],
        .opencode: ["opencode"],
        .codex: ["codex"],
        .cursor: ["cursor-agent"],
    ]

    private let home: URL
    private let shell: String?
    private let shellTimeout: TimeInterval
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var shellAnswer: (paths: [String: String], path: [String])?
    private var resolved: [Tool: String?] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, shell: String? = "/bin/zsh", shellTimeout: TimeInterval = 4) {
        self.home = home
        self.shell = shell
        self.shellTimeout = shellTimeout
    }

    public var candidateDirectories: [String] {
        let h = home.path
        var dirs = [
            "\(h)/.local/bin",
            "\(h)/.claude/local",
            "\(h)/.opencode/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(h)/.bun/bin",
            "\(h)/.npm-global/bin",
            "\(h)/.cursor/bin",
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm.path) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                dirs.append(nvm.appendingPathComponent(v).appendingPathComponent("bin").path)
            }
        }
        return dirs
    }

    public func path(for tool: Tool) -> String? {
        lock.lock()
        if let cached = resolved[tool] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = locate(tool)
        lock.lock()
        resolved[tool] = .some(found)
        lock.unlock()
        return found
    }

    public func isInstalled(_ tool: Tool) -> Bool { path(for: tool) != nil }

    public var installedTools: [Tool] {
        [Tool.claude, .opencode, .cursor, .codex].filter { isInstalled($0) }
    }

    public var fullPATH: String {
        var seen = Set<String>()
        var parts: [String] = []
        let existing = candidateDirectories.filter { fileManager.fileExists(atPath: $0) }
        let base = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for p in existing + shellResult().path + inherited + base where !p.isEmpty && !seen.contains(p) {
            seen.insert(p)
            parts.append(p)
        }
        return parts.joined(separator: ":")
    }

    public func reset() {
        lock.lock()
        resolved = [:]
        shellAnswer = nil
        lock.unlock()
    }

    private func locate(_ tool: Tool) -> String? {
        guard let names = Self.binaryNames[tool] else { return nil }
        for dir in candidateDirectories {
            for name in names {
                let p = (dir as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: p) { return p }
            }
        }
        let answer = shellResult()
        for name in names {
            if let p = answer.paths[name], fileManager.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func shellResult() -> (paths: [String: String], path: [String]) {
        lock.lock()
        if let cached = shellAnswer {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let answer = askShell()
        lock.lock()
        shellAnswer = answer
        lock.unlock()
        return answer
    }

    private func askShell() -> (paths: [String: String], path: [String]) {
        guard let shell, fileManager.isExecutableFile(atPath: shell) else { return ([:], []) }
        let names = Self.binaryNames.values.flatMap { $0 }
        let script = names.map { "printf 'KUMA_BIN %s=%s\\n' \($0) \"$(command -v \($0) 2>/dev/null)\"" }.joined(separator: "; ")
            + "; printf 'KUMA_PATH=%s\\n' \"$PATH\""
        var env = ProcessInfo.processInfo.environment
        env[KumaEnv.summaryGuard] = "1"
        let out = ProcessRunner.runSync(executable: shell, arguments: ["-lc", script], environment: env, timeout: shellTimeout)
        var paths: [String: String] = [:]
        var pathList: [String] = []
        for line in out.stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("KUMA_BIN ") {
                let body = line.dropFirst("KUMA_BIN ".count)
                guard let eq = body.firstIndex(of: "=") else { continue }
                let name = String(body[..<eq])
                let value = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/") { paths[name] = value }
            } else if line.hasPrefix("KUMA_PATH=") {
                pathList = line.dropFirst("KUMA_PATH=".count).split(separator: ":").map(String.init)
            }
        }
        return (paths, pathList)
    }
}

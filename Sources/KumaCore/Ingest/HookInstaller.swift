import Foundation

public struct HookInstaller: Sendable {
    public struct Paths: Sendable {
        public var claudeSettings: URL
        public var codexHooks: URL
        public var cursorHooks: URL
        public var opencodePlugin: URL

        public init(claudeSettings: URL, codexHooks: URL, cursorHooks: URL, opencodePlugin: URL) {
            self.claudeSettings = claudeSettings
            self.codexHooks = codexHooks
            self.cursorHooks = cursorHooks
            self.opencodePlugin = opencodePlugin
        }

        public static var `default`: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                claudeSettings: home.appendingPathComponent(".claude/settings.json"),
                codexHooks: home.appendingPathComponent(".codex/hooks.json"),
                cursorHooks: home.appendingPathComponent(".cursor/hooks.json"),
                opencodePlugin: home.appendingPathComponent(".config/opencode/plugins/kuma.js")
            )
        }
    }

    public enum InstallError: Error, Equatable {
        case unsupportedTool(Tool)
        case malformedConfig(String)
    }

    public static let marker = "kuma-hook"
    public static let backupSuffix = ".kuma-backup"
    public static let hookTimeout = 5

    public static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SubagentStop", "StopFailure", "SessionEnd"]
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
    public static let codexSyncEvents: Set<String> = ["Stop", "SessionEnd"]
    public static let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "afterAgentResponse", "stop", "subagentStop", "sessionEnd"]

    public var paths: Paths

    public init(paths: Paths = .default) {
        self.paths = paths
    }

    public static func command(hookBinary: String, tool: Tool, event: String) -> String {
        "\(shellQuote(hookBinary)) \(tool.rawValue) \(event)"
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func isInstalled(_ tool: Tool) -> Bool {
        switch tool {
        case .claude: return containsMarker(paths.claudeSettings)
        case .codex: return containsMarker(paths.codexHooks)
        case .cursor: return containsMarker(paths.cursorHooks)
        case .opencode: return FileManager.default.fileExists(atPath: paths.opencodePlugin.path)
        case .other: return false
        }
    }

    public func install(_ tool: Tool, hookBinary: String) throws {
        switch tool {
        case .claude:
            try editNestedHooks(paths.claudeSettings) { root in
                for event in HookInstaller.claudeEvents {
                    let entry = HookInstaller.handler(command: HookInstaller.command(hookBinary: hookBinary, tool: .claude, event: event), async: true)
                    HookInstaller.appendGroup(&root, event: event, group: .object([("hooks", .array([entry]))]))
                }
            }
        case .codex:
            try editNestedHooks(paths.codexHooks) { root in
                for event in HookInstaller.codexEvents {
                    let isSync = HookInstaller.codexSyncEvents.contains(event)
                    let entry = HookInstaller.handler(command: HookInstaller.command(hookBinary: hookBinary, tool: .codex, event: event), async: !isSync, timeout: event == "SessionEnd" ? 2 : HookInstaller.hookTimeout)
                    HookInstaller.appendGroup(&root, event: event, group: .object([("hooks", .array([entry]))]))
                }
            }
        case .cursor:
            try editCursor { root in
                for event in HookInstaller.cursorEvents {
                    let entry = OrderedJSON.object([
                        ("command", .string(HookInstaller.command(hookBinary: hookBinary, tool: .cursor, event: event))),
                        ("timeout", .number(String(HookInstaller.hookTimeout))),
                    ])
                    HookInstaller.appendGroup(&root, event: event, group: entry)
                }
            }
        case .opencode:
            JSONFileIO.backupOnce(paths.opencodePlugin, suffix: HookInstaller.backupSuffix)
            try JSONFileIO.writeText(OpenCodePlugin.rendered(hookBinary: hookBinary), to: paths.opencodePlugin)
        case .other:
            throw InstallError.unsupportedTool(tool)
        }
    }

    public func uninstall(_ tool: Tool) throws {
        switch tool {
        case .claude:
            guard containsMarker(paths.claudeSettings) else { return }
            try editNestedHooks(paths.claudeSettings) { _ in }
        case .codex:
            guard containsMarker(paths.codexHooks) else { return }
            try editNestedHooks(paths.codexHooks) { _ in }
        case .cursor:
            guard containsMarker(paths.cursorHooks) else { return }
            try editCursor { _ in }
        case .opencode:
            let path = paths.opencodePlugin.path
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        case .other:
            return
        }
    }

    public func installAll(hookBinary: String, tools: [Tool] = [.claude, .codex, .cursor, .opencode]) throws {
        for tool in tools { try install(tool, hookBinary: hookBinary) }
    }

    public func uninstallAll(tools: [Tool] = [.claude, .codex, .cursor, .opencode]) throws {
        for tool in tools { try uninstall(tool) }
    }

    static func handler(command: String, async: Bool, timeout: Int = HookInstaller.hookTimeout) -> OrderedJSON {
        var pairs: [(String, OrderedJSON)] = [
            ("type", .string("command")),
            ("command", .string(command)),
        ]
        if async { pairs.append(("async", .bool(true))) }
        pairs.append(("timeout", .number(String(timeout))))
        return .object(pairs)
    }

    static func appendGroup(_ root: inout OrderedJSON, event: String, group: OrderedJSON) {
        var hooks = root["hooks"] ?? .object([])
        if !hooks.isObject { hooks = .object([]) }
        var list = hooks[event]?.arrayValue ?? []
        list.append(group)
        hooks[event] = .array(list)
        root["hooks"] = hooks
    }

    static func isMarked(_ value: OrderedJSON) -> Bool {
        value["command"]?.stringValue?.contains(marker) == true
    }

    static func stripNested(_ root: inout OrderedJSON, where shouldRemove: (OrderedJSON) -> Bool) -> [String] {
        guard let events = root["hooks"]?.objectPairs else { return [] }
        var removed: [String] = []
        var kept: [(String, OrderedJSON)] = []
        for (event, value) in events {
            guard let groups = value.arrayValue else {
                kept.append((event, value))
                continue
            }
            var newGroups: [OrderedJSON] = []
            var touched = false
            for group in groups {
                guard let handlers = group["hooks"]?.arrayValue else {
                    newGroups.append(group)
                    continue
                }
                let remaining = handlers.filter { !shouldRemove($0) }
                for h in handlers where shouldRemove(h) {
                    removed.append("\(event): \(h["command"]?.stringValue ?? "")")
                }
                if remaining.count == handlers.count {
                    newGroups.append(group)
                    continue
                }
                touched = true
                if !remaining.isEmpty {
                    var g = group
                    g["hooks"] = .array(remaining)
                    newGroups.append(g)
                }
            }
            if touched, newGroups.isEmpty { continue }
            kept.append((event, .array(newGroups)))
        }
        root["hooks"] = .object(kept)
        return removed
    }

    static func stripFlat(_ root: inout OrderedJSON, where shouldRemove: (OrderedJSON) -> Bool) -> [String] {
        guard let events = root["hooks"]?.objectPairs else { return [] }
        var removed: [String] = []
        var kept: [(String, OrderedJSON)] = []
        for (event, value) in events {
            guard let entries = value.arrayValue else {
                kept.append((event, value))
                continue
            }
            let remaining = entries.filter { !shouldRemove($0) }
            for e in entries where shouldRemove(e) {
                removed.append("\(event): \(e["command"]?.stringValue ?? "")")
            }
            if remaining.isEmpty, !entries.isEmpty { continue }
            kept.append((event, .array(remaining)))
        }
        root["hooks"] = .object(kept)
        return removed
    }

    private func containsMarker(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).contains(HookInstaller.marker)
    }

    private func load(_ url: URL) throws -> OrderedJSON {
        do {
            let value = try JSONFileIO.read(url) ?? .object([])
            guard value.isObject else { throw InstallError.malformedConfig(url.path) }
            return value
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.malformedConfig(url.path)
        }
    }

    private func save(_ original: OrderedJSON, _ updated: OrderedJSON, to url: URL) throws {
        guard original != updated || !FileManager.default.fileExists(atPath: url.path) else { return }
        JSONFileIO.backupOnce(url, suffix: HookInstaller.backupSuffix)
        try JSONFileIO.write(updated, to: url)
    }

    private func editNestedHooks(_ url: URL, _ add: (inout OrderedJSON) -> Void) throws {
        let original = try load(url)
        var root = original
        _ = HookInstaller.stripNested(&root, where: HookInstaller.isMarked)
        add(&root)
        try save(original, root, to: url)
    }

    private func editCursor(_ add: (inout OrderedJSON) -> Void) throws {
        let url = paths.cursorHooks
        let original = try load(url)
        var root = original
        if root["version"] == nil {
            var pairs = root.objectPairs ?? []
            pairs.insert(("version", .number("1")), at: 0)
            root = .object(pairs)
        }
        _ = HookInstaller.stripFlat(&root, where: HookInstaller.isMarked)
        add(&root)
        try save(original, root, to: url)
    }
}

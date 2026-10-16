import Foundation
import SQLite3

public struct Discovery: Sendable {
    public var claudeSessionsDir: URL
    public var opencodeDB: URL
    public var maxAge: TimeInterval
    public var isAlive: @Sendable (Int32) -> Bool
    public var namer: ProjectNamer

    public init(
        claudeSessionsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions"),
        opencodeDB: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db"),
        maxAge: TimeInterval = 6 * 3600,
        isAlive: @escaping @Sendable (Int32) -> Bool = Discovery.processAlive,
        namer: ProjectNamer = .shared
    ) {
        self.claudeSessionsDir = claudeSessionsDir
        self.opencodeDB = opencodeDB
        self.maxAge = maxAge
        self.isAlive = isAlive
        self.namer = namer
    }

    public static let processAlive: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func discover(now: Date = Date()) -> [Session] {
        var seen = Set<String>()
        var out: [Session] = []
        for s in claudeSessions(now: now) + opencodeSessions(now: now) where !seen.contains(s.id) {
            seen.insert(s.id)
            out.append(s)
        }
        return out
    }

    static func claudeTranscript(sessionId: String, sessionsDir: URL) -> URL? {
        let projects = sessionsDir.deletingLastPathComponent().appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let file = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    public func claudeSessions(now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: claudeSessionsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [Session] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let obj = JSONValue.parse(data) else { continue }
            let pidValue = obj["pid"]?.string.flatMap { Int32($0) } ?? Int32(file.deletingPathExtension().lastPathComponent)
            guard let pid = pidValue, isAlive(pid) else { continue }
            guard let id = obj["sessionId"]?.string, !id.isEmpty else { continue }
            if let kind = obj["kind"]?.string, kind != "interactive" { continue }
            let cwd = obj["cwd"]?.string ?? ""
            let statusSince = Self.date(obj["statusUpdatedAt"]) ?? Self.date(obj["updatedAt"]) ?? Self.date(obj["startedAt"]) ?? now
            let updatedAt = Self.date(obj["updatedAt"]) ?? statusSince
            let transcript = Self.claudeTranscript(sessionId: id, sessionsDir: claudeSessionsDir).map { TranscriptReader.tail(path: $0.path, maxBytes: 262144) } ?? TranscriptInfo()
            out.append(Session(
                id: id,
                tool: .claude,
                project: namer.name(forCwd: cwd),
                cwd: cwd,
                title: transcript.title ?? obj["name"]?.string,
                model: transcript.model,
                terminal: nil,
                status: Self.claudeStatus(obj["status"]?.string),
                statusSince: statusSince,
                lastMessage: transcript.lastMessage,
                updatedAt: updatedAt
            ))
        }
        return out
    }

    public static func claudeStatus(_ raw: String?) -> SessionStatus {
        guard let r = raw?.lowercased() else { return .working }
        if r.contains("permission") || r.contains("approval") || r.contains("waiting") { return .needsApproval }
        if r.contains("question") || r.contains("input") { return .question }
        if r.contains("error") { return .error }
        if r == "idle" || r.contains("done") || r.contains("complete") { return .done }
        return .working
    }

    static func date(_ v: JSONValue?) -> Date? {
        guard let v else { return nil }
        if case .number(let n) = v { return epoch(n) }
        if case .string(let s) = v {
            if let n = Double(s) { return epoch(n) }
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    static func epoch(_ n: Double) -> Date {
        n > 1e11 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
    }

    public func opencodeSessions(now: Date = Date()) -> [Session] {
        guard FileManager.default.fileExists(atPath: opencodeDB.path) else { return [] }
        var db: OpaquePointer?
        let uri = "file:\(opencodeDB.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let cutoffMs = Int64((now.timeIntervalSince1970 - maxAge) * 1000)
        var out: [Session] = []
        var seen = Set<String>()
        for table in ["session_v2", "session"] {
            let cols = columns(db, table)
            guard ["id", "directory", "time_updated"].allSatisfy(cols.contains) else { continue }
            func col(_ name: String) -> String { cols.contains(name) ? "`\(name)`" : "NULL" }
            var whereParts = ["`time_updated` >= ?"]
            if cols.contains("time_archived") { whereParts.append("`time_archived` IS NULL") }
            if cols.contains("parent_id") { whereParts.append("`parent_id` IS NULL") }
            let sql = "SELECT `id`, `directory`, \(col("title")), \(col("model")), `time_updated`, \(col("time_idle")) FROM `\(table)` WHERE \(whereParts.joined(separator: " AND ")) ORDER BY `time_updated` DESC LIMIT 200"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = text(stmt, 0), !seen.contains(id) else { continue }
                let title = text(stmt, 2)
                if let title, title.hasPrefix(OpenCodeRunner.title) { continue }
                let dir = text(stmt, 1) ?? ""
                let updatedMs = sqlite3_column_int64(stmt, 4)
                let idleMs: Int64? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 5)
                let updated = Date(timeIntervalSince1970: Double(updatedMs) / 1000)
                let status: SessionStatus
                if let idleMs {
                    status = idleMs >= updatedMs ? .done : .working
                } else {
                    status = now.timeIntervalSince(updated) < 120 ? .working : .done
                }
                let since = idleMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? updated
                seen.insert(id)
                out.append(Session(
                    id: id,
                    tool: .opencode,
                    project: namer.name(forCwd: dir),
                    cwd: dir,
                    title: title,
                    model: Self.opencodeModel(text(stmt, 3)),
                    status: status,
                    statusSince: status == .done ? since : updated,
                    updatedAt: max(updated, since)
                ))
            }
        }
        return out
    }

    static func opencodeModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let obj = JSONValue.parse(Data(raw.utf8)), obj.object != nil {
            let id = obj["id"]?.string ?? obj["modelID"]?.string
            let provider = obj["providerID"]?.string
            switch (provider, id) {
            case let (p?, i?): return "\(p)/\(i)"
            case let (nil, i?): return i
            default: return nil
            }
        }
        return raw
    }

    private func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(`\(table)`)", -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var cols = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = text(stmt, 1) { cols.insert(name) }
        }
        return cols
    }

    private func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}

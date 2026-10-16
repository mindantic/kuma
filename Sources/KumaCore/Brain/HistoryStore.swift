import Foundation

public final class HistoryStore: @unchecked Sendable {
    struct Entry: Codable {
        var id: UUID
        var sessionId: String
        var project: String
        var tool: Tool
        var text: String
        var priority: Priority
        var voice: String
        var speed: Double
        var createdAt: Date

        init(_ b: Briefing) {
            id = b.id
            sessionId = b.sessionId
            project = b.project
            tool = b.tool
            text = b.text
            priority = b.priority
            voice = b.voice
            speed = b.speed
            createdAt = b.createdAt
        }

        var briefing: Briefing {
            Briefing(id: id, sessionId: sessionId, project: project, tool: tool, text: text, priority: priority, voice: voice, speed: speed, createdAt: createdAt)
        }
    }

    public let url: URL
    public let maxLines: Int
    private let lock = NSLock()
    private var lineCount: Int?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(url: URL = KumaPaths.history, maxLines: Int = 2000) {
        self.url = url
        self.maxLines = maxLines
    }

    public func append(_ briefing: Briefing) {
        guard var line = try? encoder.encode(Entry(briefing)) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if lineCount == nil { lineCount = readLines().count }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
        lineCount = (lineCount ?? 0) + 1
        if let n = lineCount, n > maxLines { trim() }
    }

    public func recent(limit: Int = 50) -> [Briefing] {
        lock.lock()
        let lines = readLines()
        lock.unlock()
        var out: [Briefing] = []
        for line in lines.reversed() {
            if out.count >= limit { break }
            if let e = try? decoder.decode(Entry.self, from: Data(line.utf8)) { out.append(e.briefing) }
        }
        return out
    }

    public func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: url)
        lineCount = 0
        lock.unlock()
    }

    private func readLines() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func trim() {
        let kept = readLines().suffix(max(1, maxLines - maxLines / 10))
        let text = kept.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: url, options: .atomic)
        lineCount = kept.count
    }
}

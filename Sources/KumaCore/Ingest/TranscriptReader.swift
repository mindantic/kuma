import Foundation

public struct TranscriptInfo: Equatable, Sendable {
    public var model: String?
    public var title: String?

    public init(model: String? = nil, title: String? = nil) {
        self.model = model
        self.title = title
    }
}

public enum TranscriptReader {
    public static func tail(path: String, maxBytes: Int = 65536) -> TranscriptInfo {
        let expanded = (path as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: expanded) else { return TranscriptInfo() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return TranscriptInfo() }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var info = TranscriptInfo()
        var aiTitle: String?
        var customTitle: String?
        for line in lines.reversed() {
            if info.model != nil, customTitle != nil { break }
            guard let v = JSONValue.parse(Data(line)) else { continue }
            switch v["type"]?.string {
            case "assistant":
                if info.model == nil, let m = v["message"]?["model"]?.string, !m.isEmpty, !m.hasPrefix("<") {
                    info.model = m
                }
            case "ai-title":
                if aiTitle == nil { aiTitle = nonEmpty(v["aiTitle"]?.string) }
            case "custom-title":
                if customTitle == nil { customTitle = nonEmpty(v["customTitle"]?.string ?? v["title"]?.string) }
            default:
                break
            }
        }
        info.title = customTitle ?? aiTitle
        return info
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

import Foundation

public struct TemplateSummarizer: Summarizing {
    public init() {}

    public func summarize(_ request: SummaryRequest) async -> SummaryResult {
        result(for: request)
    }

    public func result(for request: SummaryRequest) -> SummaryResult {
        let p = request.session.project
        let base = BriefingPolicy.basePriority(for: request.event.kind) ?? .normal
        let say: String
        var needs: String? = nil
        switch request.event.kind {
        case .permission:
            if let tool = Self.toolName(request.event.detail ?? request.session.pendingDetail) {
                say = "\(p) needs approval to run \(tool)."
            } else {
                say = "\(p) needs your approval."
            }
            needs = "approve or deny"
        case .question:
            say = "\(p) is asking you a question."
            needs = "answer the question"
        case .stop:
            say = "\(p) stopped and is waiting for you."
        case .error:
            say = "\(p) hit an error."
        case .subagentStop:
            say = "A subagent in \(p) stopped."
        case .sessionStart:
            say = "\(p) started a session."
        case .sessionEnd:
            say = "\(p) session ended."
        case .prompt, .toolUse:
            say = "\(p) is working."
        }
        return SummaryResult(say: say, needs: needs, priority: base, summarizedBy: nil)
    }

    static func toolName(_ detail: String?) -> String? {
        guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        let first = d.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "(" || $0 == "\n" }).first.map(String.init) ?? d
        let name = first.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).inverted)
        guard !name.isEmpty, name.count <= 40 else { return nil }
        return name
    }
}

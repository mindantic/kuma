import Foundation

public enum SummaryPrompt {
    public static let maxMessageChars = 4000

    public static func build(_ request: SummaryRequest) -> String {
        let s = request.session
        let e = request.event
        let length = request.verbosity == .line
            ? "Say one short sentence of at most 18 words."
            : "Say at most two short sentences, 35 words in total."
        let base = BriefingPolicy.basePriority(for: e.kind) ?? .normal
        var lines: [String] = [
            "You are a voice assistant that briefs a busy developer about an AI coding session. Your words will be spoken aloud.",
            "Speak as \(request.persona.name). Character: \(request.persona.tone)",
            "Rules:",
            "The character changes only the wording, never the facts.",
            length,
            "Lead with the most important point.",
            "Never say or imply the work is done, finished, complete or ready. An agent stopping its turn does not mean the task is complete.",
            "Never use the words done, finished, complete or completed.",
            "Say what the agent reported, such as what it changed, found, asked or is waiting for.",
            "If the developer must do something, say what.",
            "No markdown, no code, no file paths, no URLs, no lists.",
            "Do not invent anything that is not in the report.",
            "Refer to the project by its name.",
            "",
            "Report:",
            "Project: \(s.project)",
            "Tool: \(s.tool.displayName)",
            "Event: \(eventLabel(e.kind))",
            "Status: \(s.status.label)",
        ]
        if let t = s.title, !t.isEmpty { lines.append("Session title: \(t)") }
        if let d = s.pendingDetail ?? e.detail, !d.isEmpty { lines.append("Pending: \(truncate(d, 400))") }
        if let m = e.message ?? s.lastMessage, !m.isEmpty {
            lines.append("Last message from the agent:")
            lines.append(truncate(m, maxMessageChars))
        }
        lines.append("")
        lines.append("Answer with strict JSON only, no other text: {\"say\": \"what to speak\", \"needs\": \"what the developer must do\" or null, \"priority\": \"high\" or \"normal\" or \"fyi\"}. Use high only if the developer must act now or something is broken. Default priority is \(base.label).")
        return lines.joined(separator: "\n")
    }

    static func eventLabel(_ kind: EventKind) -> String {
        switch kind {
        case .permission: return "needs permission"
        case .question: return "asked the developer a question"
        case .stop: return "stopped and is waiting for the developer"
        case .subagentStop: return "a subagent stopped"
        case .error: return "hit an error"
        case .sessionStart: return "session started"
        case .sessionEnd: return "session ended"
        case .prompt: return "received a prompt"
        case .toolUse: return "used a tool"
        }
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.suffix(n))
    }
}

extension Priority {
    public var label: String {
        switch self {
        case .high: return "high"
        case .normal: return "normal"
        case .fyi: return "fyi"
        }
    }

    public init?(label: String) {
        switch label.lowercased().trimmingCharacters(in: .whitespaces) {
        case "high", "urgent": self = .high
        case "normal", "medium": self = .normal
        case "fyi", "low", "info": self = .fyi
        default: return nil
        }
    }
}

public enum SummaryParser {
    public static func parse(_ raw: String, base: Priority) -> SummaryResult? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let block = firstJSONObject(in: text),
           let obj = JSONValue.parse(Data(block.utf8)),
           let say = obj["say"]?.string.map(clean), !say.isEmpty {
            let needs = obj["needs"]?.string.map(clean).map(withoutCompletionClaims).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
            let priority = obj["priority"]?.string.flatMap { Priority(label: $0) } ?? base
            let spoken = withoutCompletionClaims(say)
            guard !spoken.isEmpty else { return nil }
            return SummaryResult(say: spoken, needs: needs, priority: priority)
        }
        let plain = withoutCompletionClaims(clean(text))
        guard !plain.isEmpty, !plain.hasPrefix("{") else { return nil }
        return SummaryResult(say: firstSentences(plain, 2), needs: nil, priority: base)
    }

    private static let completionRewrites: [(String, String)] = [
        (#"\b(?:is|are|was|were|has been|have been|got|gets|is now|are now|'s)\s+(?:all\s+|now\s+|fully\s+)?(?:done|finished|complete|completed)\b"#, "stopped"),
        (#"\b(?:has|have|had)\s+(?:finished|completed)(?=\s+[A-Za-z])"#, "worked on"),
        (#"\b(?:has|have|had)\s+(?:finished|completed)\b"#, "stopped"),
        (#"\b(?:finished|completed)(?=\s+(?:the|a|an|its|his|her|their|all|every|work|up)\b)"#, "worked on"),
        (#"\b(?:finished|complete|completed)(?=\s*(?:[.!?,;]|$))"#, "stopped"),
        (#"\b(?:all\s+)?done\b"#, ""),
    ]

    public static func withoutCompletionClaims(_ text: String) -> String {
        var t = text
        for (pattern, replacement) in completionRewrites {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (pattern, replacement) in [(#"\s+([,.!?;:])"#, "$1"), (#"([,;:])\s*([.!?])"#, "$2"), (#",\s*,"#, ","), (#"\s{2,}"#, " "), (#"^[\s,.;:!?]+"#, "")] {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return "" }
        if t.count <= 1, !first.isLetter { return "" }
        let original = text.trimmingCharacters(in: .whitespaces)
        return original.hasPrefix(String(first)) ? t : first.uppercased() + t.dropFirst()
    }

    public static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var depth = 0
                var inString = false
                var escaped = false
                var j = i
                while j < chars.count {
                    let c = chars[j]
                    if inString {
                        if escaped { escaped = false }
                        else if c == "\\" { escaped = true }
                        else if c == "\"" { inString = false }
                    } else if c == "\"" {
                        inString = true
                    } else if c == "{" {
                        depth += 1
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 {
                            let candidate = String(chars[i...j])
                            if JSONValue.parse(Data(candidate.utf8)) != nil { return candidate }
                            break
                        }
                    }
                    j += 1
                }
            }
            i += 1
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        var t = s
        for token in ["```json", "```", "**", "__", "`", "#"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        t = t.replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{00B7}", with: ",")
        let collapsed = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func firstSentences(_ s: String, _ n: Int) -> String {
        var count = 0
        var end = s.endIndex
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            let next = s.index(after: idx)
            if ".!?".contains(c), next == s.endIndex || s[next] == " " {
                count += 1
                if count == n {
                    end = next
                    break
                }
            }
            idx = next
        }
        return String(s[..<end]).trimmingCharacters(in: .whitespaces)
    }
}

import Foundation

indirect enum OrderedJSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    subscript(key: String) -> OrderedJSON? {
        get {
            if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
            return nil
        }
        set {
            guard case .object(var pairs) = self else { return }
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[i].1 = newValue } else { pairs.remove(at: i) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
            self = .object(pairs)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectPairs: [(String, OrderedJSON)]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isObject: Bool { objectPairs != nil }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        p.skipWhitespace()
        let v = try p.parseValue()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw ParseError.trailing(p.i) }
        return v
    }

    static func parse(_ text: String) throws -> OrderedJSON { try parse(Data(text.utf8)) }

    func serialized(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closePad = String(repeating: " ", count: level * indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): OrderedJSON.escape(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.write(into: &out, level: level + 1, indent: indent)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, (k, v)) in o.enumerated() {
                out += pad
                OrderedJSON.escape(k, into: &out)
                out += ": "
                v.write(into: &out, level: level + 1, indent: indent)
                out += i == o.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    enum ParseError: Error {
        case unexpected(Int)
        case trailing(Int)
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func parseValue() throws -> OrderedJSON {
            guard i < bytes.count else { throw ParseError.unexpected(i) }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw ParseError.unexpected(i) }
            i += w.count
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8), Double(s) != nil else {
                throw ParseError.unexpected(start)
            }
            return .number(s)
        }

        mutating func parseObject() throws -> OrderedJSON {
            i += 1
            var pairs: [(String, OrderedJSON)] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError.unexpected(i) }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError.unexpected(i) }
                i += 1
                skipWhitespace()
                pairs.append((key, try parseValue()))
                skipWhitespace()
                guard i < bytes.count else { throw ParseError.unexpected(i) }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw ParseError.unexpected(i)
            }
        }

        mutating func parseArray() throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard i < bytes.count else { throw ParseError.unexpected(i) }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError.unexpected(i)
            }
        }

        mutating func parseString() throws -> String {
            i += 1
            var buf: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: buf, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): buf.append(0x0A)
                    case UInt8(ascii: "r"): buf.append(0x0D)
                    case UInt8(ascii: "t"): buf.append(0x09)
                    case UInt8(ascii: "b"): buf.append(0x08)
                    case UInt8(ascii: "f"): buf.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: buf.append(e)
                    }
                    continue
                }
                buf.append(c)
                i += 1
            }
            throw ParseError.unexpected(i)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii), let v = UInt32(s, radix: 16) else {
                throw ParseError.unexpected(i)
            }
            i += 4
            return v
        }
    }
}

enum JSONFileIO {
    static func read(_ url: URL) throws -> OrderedJSON? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return nil }
        return try OrderedJSON.parse(data)
    }

    static func write(_ value: OrderedJSON, to url: URL) throws {
        try writeText(value.serialized() + "\n", to: url)
    }

    static func writeText(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    static func backupOnce(_ url: URL, suffix: String = ".kuma-backup") {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: url.path + suffix)
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try? fm.copyItem(at: url, to: backup)
    }
}

import AppKit
import SwiftUI
import KumaCore

enum KumaTheme {
    static let nsPurple = NSColor(name: "KumaPurple") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.72, green: 0.52, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.18, blue: 0.56, alpha: 1)
    }
    static let purple = Color(nsColor: nsPurple)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let deepPurple = Color(.sRGB, red: 0.38, green: 0.19, blue: 0.44, opacity: 1)

    static let logo: NSImage = {
        if let url = ResourceLocator.asset("app-icon.png"), let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()
}

struct KumaLogo: View {
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: KumaTheme.logo)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Kuma")
    }
}

extension Session {
    var isScratch: Bool {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", temp + "/"].contains { path.hasPrefix($0) || path + "/" == $0 }
    }

    var displayFolder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .needsApproval: return .orange
        case .question: return Color(nsColor: .systemOrange).opacity(0.85)
        case .error: return .red
        case .done: return .green
        case .working: return .blue
        case .ended: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .needsApproval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted"
        case .ended: return "moon.zzz.fill"
        }
    }

    var needsYou: Bool { self == .needsApproval || self == .question || self == .error }
}

extension Tool {
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .codex: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .other: return "questionmark.square"
        }
    }

    static var watchable: [Tool] { allCases.filter { $0 != .other } }
}

extension Mode {
    var tint: Color {
        switch self {
        case .enabled: return .green
        case .dnd: return .indigo
        case .disabled: return .secondary
        }
    }

    var explanation: String {
        switch self {
        case .enabled: return "Speaks every briefing"
        case .dnd: return "Only approvals, questions and errors"
        case .disabled: return "Silent, still tracking"
        }
    }

    var shortLabel: String {
        switch self {
        case .enabled: return "On"
        case .dnd: return "DND"
        case .disabled: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .enabled: return "speaker.wave.2.fill"
        case .dnd: return "moon.fill"
        case .disabled: return "speaker.slash.fill"
        }
    }
}

enum Elapsed {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 45 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}

struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

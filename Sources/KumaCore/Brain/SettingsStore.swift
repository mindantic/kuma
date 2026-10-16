import Combine
import Foundation

public enum PrefsScope: String, Codable, CaseIterable, Sendable {
    case session
    case project
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: KumaSettings

    public let url: URL
    private var cancellable: AnyCancellable?

    public init(url: URL = KumaPaths.settings, debounce: TimeInterval = 0.4) {
        self.url = url
        self.settings = Self.load(from: url)
        cancellable = $settings
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(debounce), scheduler: DispatchQueue.main)
            .sink { [weak self] value in self?.write(value) }
    }

    public static func load(from url: URL) -> KumaSettings {
        guard let data = try? Data(contentsOf: url) else { return KumaSettings() }
        if let decoded = try? JSONDecoder().decode(KumaSettings.self, from: data) { return decoded }
        let bak = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: url, to: bak)
        return KumaSettings()
    }

    public func save() {
        write(settings)
    }

    public func prefs(sessionId: String, project: String) -> SessionPrefs {
        settings.prefs(sessionId: sessionId, project: project)
    }

    public func scope(sessionId: String, project: String) -> PrefsScope? {
        if settings.sessionPrefs[sessionId] != nil { return .session }
        if settings.projectPrefs[project] != nil { return .project }
        return nil
    }

    public func setPrefs(_ prefs: SessionPrefs, sessionId: String, project: String, scope: PrefsScope) {
        switch scope {
        case .session:
            settings.sessionPrefs[sessionId] = prefs
        case .project:
            settings.projectPrefs[project] = prefs
            settings.sessionPrefs[sessionId] = nil
        }
    }

    public func clearSessionPrefs(sessionId: String) {
        settings.sessionPrefs[sessionId] = nil
    }

    public func clearProjectPrefs(project: String) {
        settings.projectPrefs[project] = nil
    }

    private func write(_ value: KumaSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

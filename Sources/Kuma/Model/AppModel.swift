import AppKit
import Combine
import KumaCore
import ServiceManagement
import SwiftUI

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ToastStyle: String, CaseIterable, Identifiable {
    case full, compact
    var id: String { rawValue }
    var label: String { self == .full ? "Full" : "Compact" }
}

struct ToolStatus: Equatable {
    var binaryFound: Bool
    var hookInstalled: Bool
}

extension PrefsScope: Identifiable {
    public var id: String { rawValue }
}

enum PrefsSource {
    case session
    case project
    case defaults
}

@MainActor
final class AppModel: ObservableObject {
    let useMockData: Bool

    @Published var sessions: [Session] = []
    @Published var recentBriefings: [Briefing] = []
    @Published var current: Briefing?
    @Published var pendingCount: Int = 0
    @Published var settings = KumaSettings()
    @Published var personas: [Persona] = []
    @Published var voices: [VoiceOption] = []
    @Published var toolStatus: [Tool: ToolStatus] = [:]
    @Published var voiceReady = false
    @Published var voiceInstalling = false
    @Published var toolBusy: Set<Tool> = []
    @Published var lastError: String?
    @Published var focusSessionId: String?
    @Published var toastEnabled = UserDefaults.standard.object(forKey: "toastEnabled") as? Bool ?? true
    @Published var toastStyle = ToastStyle(rawValue: UserDefaults.standard.string(forKey: "toastStyle") ?? "") ?? .full
    @Published var skipShortcut: HotKey = AppModel.loadSkipShortcut()

    var windowOpener: ((String) -> Void)?
    var settingsOpener: (() -> Void)?

    var engine: KumaEngine?
    var mockQueue: [Briefing] = []
    var mockSpeakingTask: Task<Void, Never>?

    init(useMockData: Bool = ProcessInfo.processInfo.environment["KUMA_MOCK"] == "1" || CommandLine.arguments.contains("--mock")) {
        self.useMockData = useMockData
        loadInitialState()
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var visibleSessions: [Session] { sessions.filter { !$0.isScratch } }

    var sortedSessions: [Session] {
        visibleSessions.sorted {
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.statusSince < $1.statusSince
        }
    }

    var needsYouCount: Int { visibleSessions.filter { $0.status.needsYou }.count }
    var workingCount: Int { visibleSessions.filter { $0.status == .working }.count }
    var doneCount: Int { visibleSessions.filter { $0.status == .done }.count }
    var endedCount: Int { visibleSessions.filter { $0.status == .ended }.count }
    var needsAttention: Bool { visibleSessions.contains { $0.status == .needsApproval || $0.status == .question } }

    var activePersona: Persona? { personas.first { $0.id == settings.personaId } }

    func voiceName(_ id: String?) -> String {
        guard let id else { return "Default" }
        return voices.first { $0.id == id }?.name ?? id
    }

    func setMode(_ mode: Mode) {
        settings.mode = mode
        persistSettings()
    }

    func prefs(for session: Session) -> SessionPrefs {
        settings.prefs(sessionId: session.id, project: session.project)
    }

    func prefsSource(for session: Session) -> PrefsSource {
        if settings.sessionPrefs[session.id] != nil { return .session }
        if settings.projectPrefs[session.project] != nil { return .project }
        return .defaults
    }

    func updatePrefs(session: Session, prefs: SessionPrefs, scope: PrefsScope) {
        switch scope {
        case .session:
            let fallback = settings.projectPrefs[session.project] ?? settings.defaultPrefs
            settings.sessionPrefs[session.id] = prefs == fallback ? nil : prefs
        case .project:
            settings.projectPrefs[session.project] = prefs
            for other in sessions where other.project == session.project {
                settings.sessionPrefs[other.id] = nil
            }
        }
        persistSettings()
    }

    func resetPrefs(session: Session, scope: PrefsScope) {
        switch scope {
        case .session: settings.sessionPrefs[session.id] = nil
        case .project: settings.projectPrefs[session.project] = nil
        }
        persistSettings()
    }

    func muteToggle(_ session: Session) {
        var prefs = prefs(for: session)
        prefs.muted.toggle()
        updatePrefs(session: session, prefs: prefs, scope: .session)
    }

    func skipCurrent() {
        guard let engine else { return mockSkipCurrent() }
        engine.queue.skipCurrent()
    }

    func clearAll() {
        guard let engine else { return mockClearAll() }
        engine.queue.clearAll()
    }

    func replay(_ briefing: Briefing) { enqueue(briefing.replayCopy()) }

    func testVoice() { enqueue(testBriefing()) }

    private func enqueue(_ briefing: Briefing) {
        guard let engine else { return mockEnqueue(briefing) }
        engine.enqueueManual(briefing)
    }

    func setVoice(_ voice: String) {
        settings.voice = voice
        persistSettings()
    }

    func setSpeed(_ speed: Double) {
        settings.speed = (speed * 20).rounded() / 20
        persistSettings()
    }

    func setPersona(_ id: String) {
        settings.personaId = id
        if let persona = personas.first(where: { $0.id == id }) {
            settings.voice = persona.voice
            settings.speed = persona.speed
        }
        persistSettings()
    }

    func saveCustomPersona(_ persona: Persona) {
        var saved = persona
        saved.isBuiltIn = false
        if let index = settings.customPersonas.firstIndex(where: { $0.id == saved.id }) {
            settings.customPersonas[index] = saved
        } else {
            settings.customPersonas.append(saved)
        }
        refreshPersonas()
        persistSettings()
    }

    func deletePersona(_ id: String) {
        settings.customPersonas.removeAll { $0.id == id }
        if settings.personaId == id { settings.personaId = "kuma" }
        refreshPersonas()
        persistSettings()
    }

    func installHooks(_ tool: Tool) {
        guard let engine else { return mockInstallHooks(tool) }
        runToolChange(tool) { try engine.installHooks(tool) }
    }

    func uninstallHooks(_ tool: Tool) {
        guard let engine else { return mockUninstallHooks(tool) }
        runToolChange(tool) { try engine.uninstallHooks(tool) }
    }

    func installVoice() {
        guard let engine else { return mockInstallVoice() }
        voiceInstalling = true
        Task { @MainActor in
            do {
                try await engine.installVoice { _ in }
                lastError = nil
            } catch {
                lastError = "Voice install failed: \(error.localizedDescription)"
            }
            voiceInstalling = false
        }
    }

    private func runToolChange(_ tool: Tool, _ change: () throws -> Void) {
        toolBusy.insert(tool)
        defer { toolBusy.remove(tool) }
        do {
            try change()
            lastError = nil
        } catch {
            lastError = "\(tool.displayName): \(error.localizedDescription)"
        }
    }

    func setToastEnabled(_ enabled: Bool) {
        toastEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "toastEnabled")
    }

    func setToastStyle(_ style: ToastStyle) {
        toastStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "toastStyle")
    }

    func setSkipShortcut(_ key: HotKey) {
        skipShortcut = key
        if let data = try? JSONEncoder().encode(key) { UserDefaults.standard.set(data, forKey: "skipShortcut") }
    }

    private static func loadSkipShortcut() -> HotKey {
        guard let data = UserDefaults.standard.data(forKey: "skipShortcut"), let key = try? JSONDecoder().decode(HotKey.self, from: data) else { return .default }
        return key
    }

    func setSummaryModel(_ tool: Tool, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        settings.summaryModels[tool.rawValue] = trimmed.isEmpty ? nil : trimmed
        persistSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Launch at login failed: \(error.localizedDescription)"
        }
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        persistSettings()
    }

    func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        windowOpener?(KumaWindowID.dashboard)
    }

    func openDashboard(focus session: Session) {
        focusSessionId = session.id
        openDashboard()
    }

    func setSpeakLevel(_ session: Session, muted: Bool, highOnly: Bool) {
        var prefs = prefs(for: session)
        prefs.muted = muted
        prefs.highOnly = highOnly
        updatePrefs(session: session, prefs: prefs, scope: prefsSource(for: session) == .project ? .project : .session)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsOpener?()
    }

    func quit() {
        mockSpeakingTask?.cancel()
        engine?.queue.clearAll()
        NSApp.terminate(nil)
    }

    func refreshPersonas() {
        personas = builtInPersonas() + settings.customPersonas
    }

    private func loadInitialState() {
        voices = KokoroVoices.catalog.map { VoiceOption(id: $0.id, name: $0.displayName) }
        if useMockData {
            mockLoad()
        } else {
            let engine = KumaEngine()
            self.engine = engine
            engine.attach(self)
            refreshPersonas()
            dropRedundantSessionPrefs()
        }
    }

    private func dropRedundantSessionPrefs() {
        let projects = Dictionary(sessions.map { ($0.id, $0.project) }, uniquingKeysWith: { first, _ in first })
        let redundant = settings.sessionPrefs.filter { id, prefs in
            guard let project = projects[id] else { return settings.projectPrefs.isEmpty && prefs == settings.defaultPrefs }
            return prefs == (settings.projectPrefs[project] ?? settings.defaultPrefs)
        }
        guard !redundant.isEmpty else { return }
        for id in redundant.keys { settings.sessionPrefs[id] = nil }
        persistSettings()
    }

    private func persistSettings() {
        guard let engine else { return mockPersistSettings() }
        engine.updateSettings(settings)
    }

    private func builtInPersonas() -> [Persona] {
        PersonaLibrary.all(custom: []).filter(\.isBuiltIn)
    }

    private func testBriefing() -> Briefing {
        Briefing(sessionId: "test", project: "Kuma", tool: .other, text: "Kuma here. All of your sessions are in good hands.", priority: .high, voice: settings.voice, speed: settings.speed)
    }
}

enum KumaWindowID {
    static let dashboard = "dashboard"
}

extension Briefing {
    func replayCopy() -> Briefing {
        Briefing(sessionId: sessionId, project: project, tool: tool, text: text, priority: .high, voice: voice, speed: speed)
    }
}

import AppKit
import Combine
import KumaCore
import ServiceManagement
import SwiftUI

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ToolStatus: Equatable {
    var binaryFound: Bool
    var hookInstalled: Bool
}

enum PrefsScope: String, CaseIterable, Identifiable {
    case session
    case project
    var id: String { rawValue }
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
    @Published var heardDetected = false
    @Published var toolBusy: Set<Tool> = []
    @Published var lastError: String?

    var windowOpener: ((String) -> Void)?
    var settingsOpener: (() -> Void)?

    var mockQueue: [Briefing] = []
    var mockSpeakingTask: Task<Void, Never>?

    init(useMockData: Bool = ProcessInfo.processInfo.environment["KUMA_MOCK"] != "0") {
        self.useMockData = useMockData
        loadInitialState()
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var sortedSessions: [Session] {
        sessions.sorted {
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.statusSince < $1.statusSince
        }
    }

    var needsYouCount: Int { sessions.filter { $0.status.needsYou }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var doneCount: Int { sessions.filter { $0.status == .done }.count }
    var needsAttention: Bool { sessions.contains { $0.status == .needsApproval || $0.status == .question } }

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
            settings.sessionPrefs[session.id] = prefs
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

    func skipCurrent() { mockSkipCurrent() }

    func clearAll() { mockClearAll() }

    func replay(_ briefing: Briefing) { mockEnqueue(briefing.replayCopy()) }

    func testVoice() { mockEnqueue(testBriefing()) }

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

    func installHooks(_ tool: Tool) { mockInstallHooks(tool) }

    func uninstallHooks(_ tool: Tool) { mockUninstallHooks(tool) }

    func removeHeard() { mockRemoveHeard() }

    func installVoice() { mockInstallVoice() }

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

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsOpener?()
    }

    func quit() {
        mockSpeakingTask?.cancel()
        NSApp.terminate(nil)
    }

    func refreshPersonas() {
        personas = builtInPersonas() + settings.customPersonas
    }

    private func loadInitialState() {
        if useMockData {
            mockLoad()
        } else {
            voices = MockData.kokoroVoices
            refreshPersonas()
        }
    }

    private func persistSettings() {
        mockPersistSettings()
    }

    private func builtInPersonas() -> [Persona] {
        MockData.builtInPersonas
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

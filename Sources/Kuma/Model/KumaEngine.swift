import Combine
import Foundation
import KumaCore

actor SummaryLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running >= limit {
            await withCheckedContinuation { waiters.append($0) }
        }
        running += 1
        let value = await work()
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        return value
    }
}

@MainActor
final class KumaEngine {
    let settingsStore: SettingsStore
    let sessionStore = SessionStore()
    let history = HistoryStore()
    let installer = HookInstaller()
    let locator = ToolLocator.shared
    let voiceSetup = VoiceSetup()
    let voice: FallbackVoice
    let queue: BriefingQueue

    private var summarizer: CLISummarizer
    private let limiter = SummaryLimiter(limit: 3)
    private var server: EventServer?
    private var cancellables: Set<AnyCancellable> = []
    private var housekeeping: Timer?
    private weak var model: AppModel?

    init() {
        KumaPaths.ensure()
        settingsStore = SettingsStore()
        voice = FallbackVoice(setup: VoiceSetup(), scriptURL: ResourceLocator.voiceDirectory?.appendingPathComponent("kuma_voice.py"))
        queue = BriefingQueue(voice: voice)
        summarizer = CLISummarizer(settings: settingsStore.settings)
    }

    func attach(_ model: AppModel) {
        self.model = model
        model.settings = settingsStore.settings
        model.recentBriefings = history.recent(limit: 50)
        model.voiceReady = voiceSetup.isReady

        sessionStore.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak model] in model?.sessions = $0 }
            .store(in: &cancellables)
        queue.$current
            .receive(on: RunLoop.main)
            .sink { [weak model] in model?.current = $0 }
            .store(in: &cancellables)
        queue.$pending
            .receive(on: RunLoop.main)
            .sink { [weak model] in model?.pendingCount = $0.count }
            .store(in: &cancellables)
        queue.onStarted = { [weak self] briefing in self?.recordSpoken(briefing) }

        refreshTools()
        startServer()
        discover()
        warmVoice()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tidy() }
        }
    }

    func updateSettings(_ settings: KumaSettings) {
        let previous = settingsStore.settings
        settingsStore.settings = settings
        if settings.summaryModels != previous.summaryModels || settings.commandPaths != previous.commandPaths
            || settings.summarizerRoutes != previous.summarizerRoutes || settings.customSummarizers != previous.customSummarizers {
            summarizer = CLISummarizer(settings: settings)
        }
        if settings.mode == .disabled, previous.mode != .disabled { queue.clearAll() }
        for (id, prefs) in settings.sessionPrefs where prefs.muted && previous.sessionPrefs[id]?.muted != true {
            silence(sessionId: id)
        }
        for (project, prefs) in settings.projectPrefs where prefs.muted && previous.projectPrefs[project]?.muted != true {
            for session in sessionStore.sessions where session.project == project { silence(sessionId: session.id) }
        }
    }

    func enqueueManual(_ briefing: Briefing) {
        queue.enqueue(briefing)
    }

    func detectedPath(_ tool: Tool) -> String? { locator.path(for: tool) }

    func testSummarizer(tool: Tool) async -> (text: String?, duration: TimeInterval) {
        await summarizer.runRaw(tool: tool, prompt: KumaEngine.testPrompt)
    }

    func testSummarizer(custom: CustomSummarizer) async -> (text: String?, duration: TimeInterval) {
        await CLISummarizer(settings: settingsStore.settings).runRaw(custom: custom, prompt: KumaEngine.testPrompt)
    }

    static let testPrompt = "Reply with exactly the word ok and nothing else."

    func refreshTools() {
        guard let model else { return }
        var status: [Tool: ToolStatus] = [:]
        for tool in [Tool.claude, .opencode, .codex, .cursor] {
            status[tool] = ToolStatus(binaryFound: locator.isInstalled(tool), hookInstalled: installer.isInstalled(tool))
        }
        model.toolStatus = status
    }

    func installHooks(_ tool: Tool) throws {
        guard let hook = ResourceLocator.hookBinary else { throw KumaEngineError.missingHookBinary }
        try installer.install(tool, hookBinary: hook.path)
        refreshTools()
    }

    func uninstallHooks(_ tool: Tool) throws {
        try installer.uninstall(tool)
        refreshTools()
    }

    func installVoice(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let script = ResourceLocator.voiceDirectory?.appendingPathComponent("setup.sh") else {
            throw KumaEngineError.missingVoiceScript
        }
        try await voiceSetup.install(scriptURL: script, progress: progress)
        model?.voiceReady = voiceSetup.isReady
        warmVoice()
    }

    private func startServer() {
        let server = EventServer { envelope in
            let events = Normalizers.normalize(envelope)
            guard !events.isEmpty else { return }
            Task { @MainActor [weak self] in
                for event in events { self?.process(event) }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            model?.lastError = "Kuma could not listen for sessions: \(error)"
        }
    }

    private func discover() {
        Task.detached(priority: .utility) {
            let found = Discovery().discover()
            await MainActor.run { [weak self] in self?.sessionStore.seed(found) }
        }
    }

    private func warmVoice() {
        guard voiceSetup.isReady else { return }
        let voice = self.voice
        Task.detached(priority: .utility) { await voice.warmUp() }
    }

    func process(_ event: AgentEvent) {
        let session = sessionStore.apply(event)
        guard !session.isScratch else { return }
        let settings = settingsStore.settings
        let prefs = settings.prefs(sessionId: session.id, project: session.project)
        let decision = BriefingPolicy.decide(event: event, session: session, prefs: prefs, mode: settings.mode, watched: settings.watchedTools)
        guard decision.shouldBrief else { return }
        let persona = PersonaLibrary.persona(id: prefs.personaId ?? settings.personaId, custom: settings.customPersonas)
        let request = SummaryRequest(session: session, event: event, persona: persona, verbosity: prefs.verbosity, model: settings.summaryModels[session.tool.rawValue])
        let summarizer = self.summarizer
        let limiter = self.limiter
        Task { [weak self] in
            let result = await limiter.run { await summarizer.summarize(request) }
            self?.deliver(result, session: session, base: decision.basePriority, persona: persona)
        }
    }

    private func deliver(_ result: SummaryResult, session: Session, base: Priority, persona: Persona) {
        let text = result.say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sessionStore.setSummary(sessionId: session.id, text: text)
        let settings = settingsStore.settings
        let prefs = settings.prefs(sessionId: session.id, project: session.project)
        let final = BriefingPolicy.finalPriority(base: base, summary: result)
        guard settings.mode != .disabled, !prefs.muted,
              BriefingPolicy.shouldSpeak(final: final, prefs: prefs, mode: settings.mode) else { return }
        let usesPersonaOverride = prefs.personaId != nil
        let voiceId = prefs.voice ?? (usesPersonaOverride ? persona.voice : settings.voice)
        let speed = usesPersonaOverride ? persona.speed : settings.speed
        queue.enqueue(Briefing(sessionId: session.id, project: session.project, tool: session.tool, text: spoken(text, project: session.project), priority: final, voice: voiceId, speed: speed))
    }

    private func spoken(_ text: String, project: String) -> String {
        let readable = project.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if text.lowercased().contains(project.lowercased()) || text.lowercased().contains(readable.lowercased()) { return text }
        return "\(readable). \(text)"
    }

    private func silence(sessionId: String) {
        queue.removePending(sessionId: sessionId)
        if queue.current?.sessionId == sessionId { queue.skipCurrent() }
    }

    private func recordSpoken(_ briefing: Briefing) {
        guard briefing.sessionId != "test" else { return }
        history.append(briefing)
        guard let model else { return }
        model.recentBriefings.insert(briefing, at: 0)
        if model.recentBriefings.count > 50 { model.recentBriefings.removeLast(model.recentBriefings.count - 50) }
    }

    private func tidy() {
        sessionStore.pruneEnded(olderThan: 15 * 60)
        Task.detached(priority: .utility) {
            let live = Set(Discovery().claudeSessions().map(\.id))
            await MainActor.run { [weak self] in self?.endVanished(liveClaude: live) }
        }
    }

    private func endVanished(liveClaude: Set<String>) {
        let cutoff = Date().addingTimeInterval(-120)
        for session in sessionStore.sessions where session.tool == .claude && session.status != .ended && session.updatedAt < cutoff && !liveClaude.contains(session.id) {
            _ = sessionStore.apply(AgentEvent(sessionId: session.id, tool: .claude, kind: .sessionEnd, cwd: session.cwd))
        }
    }
}

enum KumaEngineError: LocalizedError {
    case missingHookBinary
    case missingVoiceScript

    var errorDescription: String? {
        switch self {
        case .missingHookBinary: return "The kuma-hook helper is missing from the app bundle."
        case .missingVoiceScript: return "The voice setup script is missing from the app bundle."
        }
    }
}

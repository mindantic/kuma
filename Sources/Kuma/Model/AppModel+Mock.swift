import Foundation
import KumaCore

extension AppModel {
    func mockLoad() {
        sessions = MockData.sessions()
        voices = MockData.kokoroVoices
        settings = MockData.settings()
        refreshPersonas()
        toolStatus = MockData.toolStatus
        recentBriefings = MockData.recentBriefings(from: sessions, voice: settings.voice)
        voiceReady = true
    }

    func mockPersistSettings() {}

    func mockEnqueue(_ briefing: Briefing) {
        guard settings.mode != .disabled else { return }
        if settings.mode == .dnd, briefing.priority < .high { return }
        let insertAt = mockQueue.firstIndex { $0.priority < briefing.priority } ?? mockQueue.endIndex
        mockQueue.insert(briefing, at: insertAt)
        pendingCount = mockQueue.count
        mockSpeakNextIfIdle()
    }

    func mockSkipCurrent() {
        mockSpeakingTask?.cancel()
        mockSpeakingTask = nil
        current = nil
        mockSpeakNextIfIdle()
    }

    func mockClearAll() {
        mockQueue.removeAll()
        pendingCount = 0
        mockSkipCurrent()
    }

    func mockInstallHooks(_ tool: Tool) {
        mockRunToolChange(tool) { $0.hookInstalled = true }
    }

    func mockUninstallHooks(_ tool: Tool) {
        mockRunToolChange(tool) { $0.hookInstalled = false }
    }

    func mockInstallVoice() {
        voiceInstalling = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            voiceInstalling = false
            voiceReady = true
        }
    }

    func mockStartDemoBriefings() {
        let picks = sortedSessions.filter { $0.status.needsYou || $0.status == .done }.prefix(4)
        for session in picks {
            mockEnqueue(Briefing(sessionId: session.id, project: session.project, tool: session.tool, text: session.lastSummary ?? "Finished.", priority: session.status.needsYou ? .high : .normal, voice: settings.voice, speed: settings.speed))
        }
    }

    private func mockSpeakNextIfIdle() {
        guard current == nil, !mockQueue.isEmpty else {
            pendingCount = mockQueue.count
            return
        }
        let next = mockQueue.removeFirst()
        pendingCount = mockQueue.count
        current = next
        recentBriefings.insert(next, at: 0)
        if recentBriefings.count > 50 { recentBriefings.removeLast(recentBriefings.count - 50) }
        let seconds = mockSpeakingDuration(next)
        mockSpeakingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.current?.id == next.id else { return }
            self.current = nil
            self.mockSpeakNextIfIdle()
        }
    }

    private func mockSpeakingDuration(_ briefing: Briefing) -> Double {
        let base = ProcessInfo.processInfo.environment["KUMA_DEMO_HOLD"].flatMap(Double.init) ?? 3
        return base + Double(briefing.text.count) * 0.06 / max(0.5, briefing.speed)
    }

    private func mockRunToolChange(_ tool: Tool, change: @escaping (inout ToolStatus) -> Void) {
        toolBusy.insert(tool)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            var status = toolStatus[tool] ?? ToolStatus(binaryFound: false, hookInstalled: false)
            change(&status)
            toolStatus[tool] = status
            toolBusy.remove(tool)
        }
    }
}

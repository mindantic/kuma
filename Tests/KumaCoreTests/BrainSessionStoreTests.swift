import XCTest
@testable import KumaCore

func brainTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-brain-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func brainEvent(_ kind: EventKind, id: String = "s1", tool: Tool = .claude, cwd: String = "/tmp/bion", at t: TimeInterval = 0, model: String? = nil, title: String? = nil, message: String? = nil, detail: String? = nil, terminal: String? = nil) -> AgentEvent {
    AgentEvent(sessionId: id, tool: tool, kind: kind, cwd: cwd, model: model, title: title, message: message, detail: detail, terminal: terminal, timestamp: Date(timeIntervalSince1970: 1_000_000 + t))
}

@MainActor
final class BrainSessionStoreTests: XCTestCase {
    func testTransitions() {
        let store = SessionStore(namer: ProjectNamer())
        var s = store.apply(brainEvent(.sessionStart, model: "opus", title: "fix login", terminal: "iTerm2"))
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.project, "bion")
        XCTAssertEqual(s.statusSince, Date(timeIntervalSince1970: 1_000_000))

        s = store.apply(brainEvent(.toolUse, at: 5))
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.statusSince, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(s.model, "opus")
        XCTAssertEqual(s.title, "fix login")
        XCTAssertEqual(s.terminal, "iTerm2")
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 1_000_005))

        s = store.apply(brainEvent(.permission, at: 10, detail: "Bash"))
        XCTAssertEqual(s.status, .needsApproval)
        XCTAssertEqual(s.pendingDetail, "Bash")
        XCTAssertEqual(s.statusSince, Date(timeIntervalSince1970: 1_000_010))

        s = store.apply(brainEvent(.question, at: 12, message: "Which db?"))
        XCTAssertEqual(s.status, .question)
        XCTAssertEqual(s.pendingDetail, "Which db?")

        s = store.apply(brainEvent(.prompt, at: 15))
        XCTAssertEqual(s.status, .working)
        XCTAssertNil(s.pendingDetail)

        s = store.apply(brainEvent(.subagentStop, at: 18))
        XCTAssertEqual(s.status, .working)
        XCTAssertEqual(s.statusSince, Date(timeIntervalSince1970: 1_000_015))
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 1_000_018))

        s = store.apply(brainEvent(.stop, at: 20, message: "All tests pass."))
        XCTAssertEqual(s.status, .done)
        XCTAssertEqual(s.lastMessage, "All tests pass.")

        s = store.apply(brainEvent(.error, at: 25, message: "rate limited"))
        XCTAssertEqual(s.status, .error)

        s = store.apply(brainEvent(.sessionEnd, at: 30))
        XCTAssertEqual(s.status, .ended)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testSortingByUrgencyThenRecency() {
        let store = SessionStore(namer: ProjectNamer())
        store.apply(brainEvent(.stop, id: "done-old", at: 1))
        store.apply(brainEvent(.stop, id: "done-new", at: 50))
        store.apply(brainEvent(.toolUse, id: "work", at: 100))
        store.apply(brainEvent(.permission, id: "perm", at: 2))
        store.apply(brainEvent(.question, id: "ask", at: 3))
        store.apply(brainEvent(.sessionEnd, id: "gone", at: 200))
        store.apply(brainEvent(.error, id: "err", at: 4))
        XCTAssertEqual(store.sessions.map(\.id), ["perm", "ask", "err", "done-new", "done-old", "work", "gone"])
        XCTAssertEqual(store.count(.done), 2)
        XCTAssertEqual(store.counts[.needsApproval], 1)
        XCTAssertEqual(store.attentionCount, 3)
    }

    func testSummaryRemovePruneSeed() {
        let store = SessionStore(namer: ProjectNamer())
        store.apply(brainEvent(.stop, id: "a"))
        store.setSummary(sessionId: "a", text: "bion is done.")
        XCTAssertEqual(store.session(id: "a")?.lastSummary, "bion is done.")
        store.apply(brainEvent(.sessionEnd, id: "b", at: 0))
        store.apply(brainEvent(.sessionEnd, id: "c", at: 1000))
        store.pruneEnded(olderThan: 500, now: Date(timeIntervalSince1970: 1_001_100))
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["a", "c"])
        store.remove(sessionId: "a")
        XCTAssertEqual(store.sessions.map(\.id), ["c"])

        let seeded = Session(id: "d", tool: .opencode, project: "", cwd: "/tmp/postical", status: .done, updatedAt: Date(timeIntervalSince1970: 5))
        store.seed([seeded])
        XCTAssertEqual(store.session(id: "d")?.project, "postical")
        store.apply(brainEvent(.permission, id: "d", tool: .opencode, cwd: "/tmp/postical", at: 10))
        store.seed([seeded])
        XCTAssertEqual(store.session(id: "d")?.status, .needsApproval)
    }
}

final class BrainProjectNamerTests: XCTestCase {
    func writeConfig(_ gitDir: URL, url: String?) throws {
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        var text = "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = git@github.com:other/wrong.git\n"
        if let url { text += "[remote \"origin\"]\n\turl = \(url)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
        try text.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    func testOriginFromNestedDirectory() throws {
        let root = brainTempDir().appendingPathComponent("localname")
        try writeConfig(root.appendingPathComponent(".git"), url: "git@github.com:mindantic/bion.git")
        let nested = root.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectNamer.resolve(cwd: nested.path), "bion")
    }

    func testHttpsRemote() {
        XCTAssertEqual(ProjectNamer.repoName(fromRemote: "https://github.com/mindantic/postical.git"), "postical")
        XCTAssertEqual(ProjectNamer.repoName(fromRemote: "https://github.com/mindantic/postical/"), "postical")
        XCTAssertEqual(ProjectNamer.repoName(fromRemote: "git@github.com:repo.git"), "repo")
    }

    func testNoOriginFallsBackToFolder() throws {
        let root = brainTempDir().appendingPathComponent("plainfolder")
        try writeConfig(root.appendingPathComponent(".git"), url: nil)
        XCTAssertEqual(ProjectNamer.resolve(cwd: root.path), "plainfolder")
        let nonGit = brainTempDir().appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectNamer.resolve(cwd: nonGit.path), "loose")
    }

    func testWorktreeGitFile() throws {
        let base = brainTempDir()
        let main = base.appendingPathComponent("kuma-main")
        try writeConfig(main.appendingPathComponent(".git"), url: "https://github.com/mindantic/kuma.git")
        let wtGit = main.appendingPathComponent(".git/worktrees/kuma-wt")
        try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try "../..\n".write(to: wtGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let wt = base.appendingPathComponent("kuma-wt-brain")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectNamer.resolve(cwd: wt.path), "kuma")

        try FileManager.default.removeItem(at: wtGit.appendingPathComponent("commondir"))
        XCTAssertEqual(ProjectNamer.resolve(cwd: wt.path), "kuma")
    }

    func testCacheIsPerCwd() throws {
        let root = brainTempDir().appendingPathComponent("cached")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let namer = ProjectNamer()
        XCTAssertEqual(namer.name(forCwd: root.path), "cached")
        try writeConfig(root.appendingPathComponent(".git"), url: "git@github.com:x/renamed.git")
        XCTAssertEqual(namer.name(forCwd: root.path), "cached")
        XCTAssertEqual(ProjectNamer().name(forCwd: root.path), "renamed")
    }
}

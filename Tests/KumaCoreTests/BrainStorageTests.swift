import SQLite3
import XCTest
@testable import KumaCore

@MainActor
final class BrainSettingsTests: XCTestCase {
    func testMissingFileGivesDefaults() {
        let url = brainTempDir().appendingPathComponent("settings.json")
        XCTAssertEqual(SettingsStore(url: url).settings, KumaSettings())
    }

    func testCorruptFileKeepsBackup() throws {
        let url = brainTempDir().appendingPathComponent("settings.json")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url)
        XCTAssertEqual(store.settings, KumaSettings())
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8), "{not json")
    }

    func testRoundTripAndScopes() async throws {
        let url = brainTempDir().appendingPathComponent("settings.json")
        let store = SettingsStore(url: url, debounce: 0.05)
        store.settings.mode = .dnd
        store.setPrefs(SessionPrefs(highOnly: true), sessionId: "s1", project: "bion", scope: .session)
        XCTAssertEqual(store.scope(sessionId: "s1", project: "bion"), .session)
        store.setPrefs(SessionPrefs(muted: true), sessionId: "s1", project: "bion", scope: .project)
        XCTAssertEqual(store.scope(sessionId: "s1", project: "bion"), .project)
        XCTAssertTrue(store.prefs(sessionId: "s1", project: "bion").muted)
        XCTAssertTrue(store.prefs(sessionId: "s2", project: "bion").muted)
        store.setPrefs(SessionPrefs(verbosity: .summary), sessionId: "s2", project: "bion", scope: .session)
        XCTAssertEqual(store.prefs(sessionId: "s2", project: "bion").verbosity, .summary)
        store.clearSessionPrefs(sessionId: "s2")
        XCTAssertTrue(store.prefs(sessionId: "s2", project: "bion").muted)

        try await Task.sleep(nanoseconds: 400_000_000)
        let reloaded = SettingsStore(url: url)
        XCTAssertEqual(reloaded.settings, store.settings)
        XCTAssertEqual(reloaded.settings.mode, .dnd)

        store.settings.speed = 1.3
        store.save()
        XCTAssertEqual(SettingsStore.load(from: url).speed, 1.3)
    }
}

final class BrainHistoryTests: XCTestCase {
    func testAppendRecentAndTrim() {
        let url = brainTempDir().appendingPathComponent("history.jsonl")
        let store = HistoryStore(url: url, maxLines: 20)
        for i in 0..<45 {
            store.append(Briefing(sessionId: "s\(i)", project: "bion", tool: .claude, text: "line \(i)", priority: .normal, voice: "am_onyx", speed: 1))
        }
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
        XCTAssertLessThanOrEqual(lines, 20)
        let recent = store.recent(limit: 3)
        XCTAssertEqual(recent.map(\.text), ["line 44", "line 43", "line 42"])
        XCTAssertEqual(HistoryStore(url: url).recent(limit: 1).first?.text, "line 44")
    }
}

final class BrainDiscoveryTests: XCTestCase {
    func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    func testClaudeSessionFiles() throws {
        let dir = brainTempDir()
        let me = getpid()
        let alive = """
        {"pid":\(me),"sessionId":"abc","cwd":"/tmp/postical","name":"writer","status":"busy","updatedAt":1792128284144,"statusUpdatedAt":1792128284000,"kind":"interactive"}
        """
        let idle = """
        {"pid":\(me),"sessionId":"idle1","cwd":"/tmp/bion","status":"idle","statusUpdatedAt":1792128284000}
        """
        let dead = """
        {"pid":999999,"sessionId":"dead","cwd":"/tmp/x","status":"busy"}
        """
        try alive.write(to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try idle.write(to: dir.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
        try dead.write(to: dir.appendingPathComponent("3.json"), atomically: true, encoding: .utf8)
        try "garbage".write(to: dir.appendingPathComponent("4.json"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("5.abc.key"), atomically: true, encoding: .utf8)
        let d = Discovery(claudeSessionsDir: dir, opencodeDB: dir.appendingPathComponent("none.db"), isAlive: { $0 == me }, namer: ProjectNamer())
        let found = d.discover().sorted { $0.id < $1.id }
        XCTAssertEqual(found.map(\.id), ["abc", "idle1"])
        XCTAssertEqual(found[0].status, .working)
        XCTAssertEqual(found[0].title, "writer")
        XCTAssertEqual(found[0].project, "postical")
        XCTAssertEqual(found[0].statusSince, Date(timeIntervalSince1970: 1792128284.0))
        XCTAssertEqual(found[1].status, .done)
    }

    func testOpenCodeDatabase() throws {
        let dir = brainTempDir()
        let path = dir.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text, parent_id text, directory text NOT NULL, title text, model text, time_updated integer NOT NULL, time_idle integer, time_archived integer)")
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL, title text NOT NULL, time_updated integer NOT NULL, time_archived integer)")
        let now = Date(timeIntervalSince1970: 1_792_134_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let recent = nowMs - 60_000
        let old = nowMs - 7 * 3600 * 1000
        exec(db, "INSERT INTO session_v2 VALUES ('a','p',NULL,'/tmp/bion','Fix auth','{\"id\":\"glm-5.3\",\"providerID\":\"zai\"}',\(recent),NULL,NULL)")
        exec(db, "INSERT INTO session_v2 VALUES ('b','p',NULL,'/tmp/postical','Idle one',NULL,\(recent),\(recent + 1000),NULL)")
        exec(db, "INSERT INTO session_v2 VALUES ('c','p',NULL,'/tmp/x','Archived',NULL,\(recent),NULL,\(recent))")
        exec(db, "INSERT INTO session_v2 VALUES ('d','p',NULL,'/tmp/x','Old',NULL,\(old),NULL,NULL)")
        exec(db, "INSERT INTO session_v2 VALUES ('e','p',NULL,'/tmp/x','kuma-summary',NULL,\(recent),NULL,NULL)")
        exec(db, "INSERT INTO session_v2 VALUES ('f','p','a','/tmp/x','child',NULL,\(recent),NULL,NULL)")
        exec(db, "INSERT INTO session VALUES ('g','/tmp/legacy','Legacy',\(recent),NULL)")
        exec(db, "INSERT INTO session VALUES ('a','/tmp/bion','dup',\(recent),NULL)")
        sqlite3_close(db)

        let d = Discovery(claudeSessionsDir: dir.appendingPathComponent("nope"), opencodeDB: URL(fileURLWithPath: path), namer: ProjectNamer())
        let found = Dictionary(uniqueKeysWithValues: d.opencodeSessions(now: now).map { ($0.id, $0) })
        XCTAssertEqual(Set(found.keys), ["a", "b", "g"])
        XCTAssertEqual(found["a"]?.status, .working)
        XCTAssertEqual(found["a"]?.model, "zai/glm-5.3")
        XCTAssertEqual(found["a"]?.title, "Fix auth")
        XCTAssertEqual(found["a"]?.project, "bion")
        XCTAssertEqual(found["b"]?.status, .done)
        XCTAssertEqual(found["g"]?.status, .working)
        XCTAssertEqual(found["g"]?.tool, .opencode)
    }
}

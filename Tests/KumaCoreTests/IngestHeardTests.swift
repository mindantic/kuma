import XCTest
@testable import KumaCore

final class IngestHeardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".heard"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fixtureSettings(heard: String) -> String {
        """
        {
          "model": "opus",
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  { "type": "command", "command": "node ~/.claude/hooks/context-mode-cache-heal.mjs" },
                  { "type": "command", "command": "\(heard)/save-terminal-binding.sh" }
                ]
              }
            ],
            "PreToolUse": [
              { "matcher": "Write|Edit", "hooks": [{ "type": "command", "command": "node no-comments.mjs" }] },
              { "hooks": [
                  { "type": "command", "command": "/Applications/Heard.app/Contents/MacOS/heard-hook claude-code", "async": true },
                  { "type": "command", "command": "\(heard)/save-session-state.sh" }
              ] },
              { "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "\(heard)/save-pending-question.sh", "timeout": 600 }] },
              { "matcher": "*", "hooks": [{ "type": "command", "command": "if [ -n \\"$ORCA_AGENT_HOOK_PORT\\" ]; then orca; fi", "timeout": 10 }] }
            ],
            "PreCompact": [
              { "hooks": [{ "type": "command", "command": "\(heard)/save-session-state.sh" }] }
            ]
          },
          "statusLine": {
            "type": "command",
            "command": "\(heard)/statusline-usage.sh"
          }
        }

        """
    }

    private let wrapper = """
    #!/usr/bin/env bash
    input=$(cat)
    H=/Applications/Heard.app/Contents/MacOS/heard-hook
    [ -x "$H" ] && printf '%s' "$input" | "$H" statusline >/dev/null 2>&1
    printf "%s" "$input" | /usr/local/bin/node ~/.claude/statusline.js

    """

    func testPlanAndApplyRemoveHeardAndRestoreStatusLineFromWrapper() throws {
        let heard = dir.appendingPathComponent(".heard").path
        let settings = dir.appendingPathComponent("claude/settings.json")
        let codex = dir.appendingPathComponent("codex/hooks.json")
        try fixtureSettings(heard: heard).write(to: settings, atomically: true, encoding: .utf8)
        try wrapper.write(toFile: heard + "/statusline-usage.sh", atomically: true, encoding: .utf8)
        try """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(heard)/codex-observer.sh","timeout":60},{"type":"command","command":"/opt/kuma/kuma-hook codex Stop"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"\(heard)/save-session-state.sh"}]}]}}
        """.write(to: codex, atomically: true, encoding: .utf8)

        let remover = HeardRemover(claudeSettings: settings, codexHooks: codex, heardHome: dir.appendingPathComponent(".heard"))
        let plan = remover.plan()
        XCTAssertEqual(plan.filter { $0.hasPrefix("Claude: remove hook") }.count, 5)
        XCTAssertEqual(plan.filter { $0.hasPrefix("Codex: remove hook") }.count, 2)
        XCTAssertTrue(plan.contains("Claude: restore statusLine to /usr/local/bin/node ~/.claude/statusline.js"))

        try remover.apply()
        XCTAssertTrue(remover.plan().isEmpty)
        let root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: settings)))
        XCTAssertEqual(root["statusLine"]?["command"]?.string, "/usr/local/bin/node ~/.claude/statusline.js")
        XCTAssertEqual(root["hooks"]?["SessionStart"]?[0]?["hooks"]?.array?.count, 1)
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?.array?.count, 2)
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?[1]?["matcher"]?.string, "*")
        XCTAssertNil(root["hooks"]?["PreCompact"])
        let codexRoot = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: codex)))
        XCTAssertEqual(codexRoot["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"]?.string, "/opt/kuma/kuma-hook codex Stop")
        XCTAssertNil(codexRoot["hooks"]?["SessionEnd"])

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("claude").path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("settings.json.kuma-heard-backup-") })
    }

    func testStatusLinePrefersHeardBackupWithExtraFields() throws {
        let heard = dir.appendingPathComponent(".heard").path
        let settings = dir.appendingPathComponent("claude/settings.json")
        try fixtureSettings(heard: heard).write(to: settings, atomically: true, encoding: .utf8)
        try #"{"statusLine":{"type":"command","command":"node ~/.claude/statusline.js","padding":0,"refreshInterval":10}}"#
            .write(to: dir.appendingPathComponent("claude/settings.json.heard-bak"), atomically: true, encoding: .utf8)
        let remover = HeardRemover(claudeSettings: settings, codexHooks: dir.appendingPathComponent("codex/none.json"), heardHome: dir.appendingPathComponent(".heard"))
        try remover.apply()
        let root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: settings)))
        XCTAssertEqual(root["statusLine"]?["refreshInterval"]?.string, "10")
        XCTAssertEqual(root["statusLine"]?["command"]?.string, "node ~/.claude/statusline.js")
    }

    func testAgainstCopiesOfRealFiles() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let realSettings = home.appendingPathComponent(".claude/settings.json")
        let realCodex = home.appendingPathComponent(".codex/hooks.json")
        guard FileManager.default.fileExists(atPath: realSettings.path) else { throw XCTSkip("no real Claude settings") }
        let settings = dir.appendingPathComponent("claude/settings.json")
        let codex = dir.appendingPathComponent("codex/hooks.json")
        try FileManager.default.copyItem(at: realSettings, to: settings)
        if FileManager.default.fileExists(atPath: realCodex.path) { try FileManager.default.copyItem(at: realCodex, to: codex) }
        let realSettingsBefore = try Data(contentsOf: realSettings)

        let remover = HeardRemover(claudeSettings: settings, codexHooks: codex, heardHome: home.appendingPathComponent(".heard"))
        let plan = remover.plan()
        print("HEARD PLAN (\(plan.count) changes):\n" + plan.joined(separator: "\n"))
        try remover.apply()
        XCTAssertTrue(remover.plan().isEmpty)
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains("heard-hook"))
        XCTAssertFalse(text.contains("/.heard/"))
        XCTAssertNotNil(JSONValue.parse(Data(text.utf8)))
        XCTAssertEqual(try Data(contentsOf: realSettings), realSettingsBefore)

        let installer = HookInstaller(paths: .init(claudeSettings: settings, codexHooks: codex, cursorHooks: dir.appendingPathComponent("cursor.json"), opencodePlugin: dir.appendingPathComponent("kuma.js")))
        let afterHeard = text
        try installer.install(.claude, hookBinary: "/Applications/Kuma.app/Contents/MacOS/kuma-hook")
        try installer.uninstall(.claude)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), afterHeard)
    }
}

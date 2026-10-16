import XCTest
@testable import KumaCore

final class IngestInstallerTests: XCTestCase {
    private var dir: URL!
    private var installer: HookInstaller!
    private let binary = "/Applications/Kuma.app/Contents/MacOS/kuma-hook"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-inst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        installer = HookInstaller(paths: .init(
            claudeSettings: dir.appendingPathComponent("claude/settings.json"),
            codexHooks: dir.appendingPathComponent("codex/hooks.json"),
            cursorHooks: dir.appendingPathComponent("cursor/hooks.json"),
            opencodePlugin: dir.appendingPathComponent("opencode/plugins/kuma.js")
        ))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private let claudeFixture = """
    {
      "env": {
        "FOO": "1"
      },
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Write|Edit",
            "hooks": [
              {
                "type": "command",
                "command": "node ~/.claude/hooks/no-comments.mjs"
              }
            ]
          }
        ],
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/notify \\"done\\" é"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "node ~/.claude/statusline.js",
        "padding": 0
      }
    }

    """

    func testClaudeInstallMergesIdempotentAndUninstallKeepsForeignHooks() throws {
        let url = installer.paths.claudeSettings
        try write(claudeFixture, url)
        XCTAssertFalse(installer.isInstalled(.claude))

        try installer.install(.claude, hookBinary: binary)
        XCTAssertTrue(installer.isInstalled(.claude))
        let once = try read(url)
        XCTAssertEqual(try read(URL(fileURLWithPath: url.path + ".kuma-backup")), claudeFixture)

        let root = try XCTUnwrap(JSONValue.parse(Data(once.utf8)))
        for event in HookInstaller.claudeEvents {
            let groups = try XCTUnwrap(root["hooks"]?[event]?.array, event)
            let kuma = groups.flatMap { $0["hooks"]?.array ?? [] }.filter { $0["command"]?.string?.contains("kuma-hook") == true }
            XCTAssertEqual(kuma.count, 1, event)
            XCTAssertEqual(kuma.first?["command"]?.string, "\(binary) claude \(event)")
            XCTAssertEqual(kuma.first?["async"]?.bool, true)
            XCTAssertEqual(kuma.first?["timeout"]?.string, "5")
        }
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?[0]?["matcher"]?.string, "Write|Edit")
        XCTAssertEqual(root["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"]?.string, "/usr/local/bin/notify \"done\" \u{e9}")
        let keys = once.components(separatedBy: "\n").filter { $0.hasPrefix("  \"") }.map { $0.split(separator: ":")[0] }
        XCTAssertEqual(keys, ["  \"env\"", "  \"model\"", "  \"hooks\"", "  \"statusLine\""])

        try installer.install(.claude, hookBinary: binary)
        XCTAssertEqual(try read(url), once)

        try installer.uninstall(.claude)
        XCTAssertFalse(installer.isInstalled(.claude))
        XCTAssertEqual(try read(url), claudeFixture)
    }

    func testCodexInstallUsesSyncStop() throws {
        let url = installer.paths.codexHooks
        try write(#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}]}}"#, url)
        try installer.install(.codex, hookBinary: "/Users/me/Library/Application Support/Kuma/kuma-hook")
        let root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        let stop = try XCTUnwrap(root["hooks"]?["Stop"]?[0]?["hooks"]?[0])
        XCTAssertEqual(stop["command"]?.string, "'/Users/me/Library/Application Support/Kuma/kuma-hook' codex Stop")
        XCTAssertNil(stop["async"])
        XCTAssertEqual(root["hooks"]?["PermissionRequest"]?[0]?["hooks"]?[0]?["async"]?.bool, true)
        XCTAssertEqual(root["hooks"]?["PreToolUse"]?.array?.count, 1)
        try installer.uninstall(.codex)
        let after = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        XCTAssertEqual(after["hooks"]?.object?.keys.sorted(), ["PreToolUse"])
    }

    func testCursorInstallCreatesVersionedFileAndUninstallKeepsOrca() throws {
        let url = installer.paths.cursorHooks
        try installer.install(.cursor, hookBinary: binary)
        var root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        XCTAssertEqual(root["version"]?.string, "1")
        XCTAssertEqual(root["hooks"]?["afterAgentResponse"]?[0]?["command"]?.string, "\(binary) cursor afterAgentResponse")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".kuma-backup"))

        try write(#"{"version":1,"hooks":{"stop":[{"command":"/bin/sh orca-cursor-hook.sh","timeout":10}]}}"#, url)
        try installer.install(.cursor, hookBinary: binary)
        root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        XCTAssertEqual(root["hooks"]?["stop"]?.array?.count, 2)
        try installer.uninstall(.cursor)
        root = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        XCTAssertEqual(root["hooks"]?["stop"]?.array?.count, 1)
        XCTAssertNil(root["hooks"]?["afterAgentResponse"])
    }

    func testOpenCodePluginInstallSubstitutesBinary() throws {
        try installer.install(.opencode, hookBinary: "/Users/me/Kuma \"x\"/kuma-hook")
        XCTAssertTrue(installer.isInstalled(.opencode))
        let text = try read(installer.paths.opencodePlugin)
        XCTAssertTrue(text.contains(#"const KUMA_HOOK = "/Users/me/Kuma \"x\"/kuma-hook";"#))
        XCTAssertTrue(text.contains(#"const UNSET = "__KUMA_" + "HOOK__";"#))
        try installer.uninstall(.opencode)
        XCTAssertFalse(installer.isInstalled(.opencode))
    }

    func testEmbeddedPluginMatchesIntegrationsFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("Integrations/opencode/kuma.js"), encoding: .utf8)
        XCTAssertEqual(OpenCodePlugin.source + "\n", file)
    }

    func testOrderedJSONRoundTripsRealConfigShapes() throws {
        let text = #"{"a":[1,2.5,-3e2,true,false,null],"b":{"c":"line\nbreak \"q\" \\ \t tab \u0001 emoji 😀 / slash"},"e":{},"f":[]}"#
        let v = try OrderedJSON.parse(text)
        let out = v.serialized()
        XCTAssertEqual(try OrderedJSON.parse(out), v)
        XCTAssertTrue(out.contains("\"a\": [\n    1,\n    2.5,\n    -3e2"))
        XCTAssertTrue(out.contains("\\u0001 emoji \u{1F600} / slash"))
        XCTAssertTrue(out.contains("\"e\": {},\n  \"f\": []"))
        let viaFoundation = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual((viaFoundation?["b"] as? [String: Any])?["c"] as? String, "line\nbreak \"q\" \\ \t tab \u{1} emoji \u{1F600} / slash")
    }
}

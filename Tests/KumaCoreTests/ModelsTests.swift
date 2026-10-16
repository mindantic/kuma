import XCTest
@testable import KumaCore

final class ModelsTests: XCTestCase {
    func testPrefsFallBackFromSessionToProjectToDefault() {
        var s = KumaSettings()
        s.projectPrefs["bion"] = SessionPrefs(muted: true)
        XCTAssertTrue(s.prefs(sessionId: "x", project: "bion").muted)
        s.sessionPrefs["x"] = SessionPrefs(muted: false, highOnly: true)
        XCTAssertTrue(s.prefs(sessionId: "x", project: "bion").highOnly)
        XCTAssertFalse(s.prefs(sessionId: "y", project: "other").muted)
    }

    func testJSONValueParsesHookPayload() {
        let v = JSONValue.parse(Data(#"{"session_id":"a","n":3,"ok":true,"list":[1]}"#.utf8))
        XCTAssertEqual(v?["session_id"]?.string, "a")
        XCTAssertEqual(v?["n"]?.string, "3")
        XCTAssertEqual(v?["ok"]?.bool, true)
        XCTAssertEqual(v?["list"]?[0]?.string, "1")
    }
}

import XCTest

/// What the real-server tests share: the environment they need and the Settings steps.
struct RealServer {
    let address: String
    let token: String
    /// An audio file on the Mac that stands in for the microphone.
    let micFile: String

    /// The server from `SPEAKUP_SERVER`, `SPEAKUP_TOKEN` and `SPEAKUP_MIC_FILE`, or a skip.
    /// Pass them to `xcodebuild` with the `TEST_RUNNER_` prefix, which the test runner strips.
    static func fromEnvironment() throws -> RealServer {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["SPEAKUP_SERVER"], let token = environment["SPEAKUP_TOKEN"],
            let micFile = environment["SPEAKUP_MIC_FILE"]
        else {
            throw XCTSkip("Set SPEAKUP_SERVER, SPEAKUP_TOKEN and SPEAKUP_MIC_FILE to run against a real server.")
        }
        return RealServer(address: address, token: token, micFile: micFile)
    }

    /// GETs a path of the server's API and decodes the JSON object it returns.
    func get(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + path)))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "GET \(path)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "GET \(path)")
    }
}

extension XCUIApplication {
    /// Saves the token in Settings, which opens by itself on a fresh install, checks the
    /// connection, calls `connected`, and closes Settings.
    func saveServerToken(_ token: String, connected: () -> Void = {}) {
        let settings = navigationBars["Settings"]
        if !settings.waitForExistence(timeout: 5) {
            XCTAssertTrue(buttons["Settings"].waitForExistence(timeout: 5))
            buttons["Settings"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        for label in ["Add token", "Replace"] where buttons[label].exists {
            buttons[label].tap()
        }
        let field = secureTextFields["Token"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(token)
        buttons["Test connection"].tap()
        XCTAssertTrue(staticTexts["The server answered"].waitForExistence(timeout: 15))
        connected()
        settings.buttons["Done"].tap()
    }
}

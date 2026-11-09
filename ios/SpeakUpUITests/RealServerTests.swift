import XCTest

/// One home-practice loop against a real analysis server: settings, a prepared take, its
/// report, a retry and the comparison.
///
/// It is skipped unless these are set (pass them to `xcodebuild` with the `TEST_RUNNER_`
/// prefix, which the test runner strips):
///
/// - `SPEAKUP_SERVER`: the server address, for example `http://127.0.0.1:18780` for a server
///   on the Mac running the simulator.
/// - `SPEAKUP_TOKEN`: that server's token.
/// - `SPEAKUP_MIC_FILE`: an audio file on the Mac that stands in for the microphone.
///
/// The recording runs for `SPEAKUP_RECORD_SECONDS` (default 15) of that file, so the server
/// has real speech to transcribe. It works with or without coaching on the server.
@MainActor
final class RealServerTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testHomeLoopAgainstRealServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SPEAKUP_SERVER"], let token = environment["SPEAKUP_TOKEN"],
            let micFile = environment["SPEAKUP_MIC_FILE"]
        else {
            throw XCTSkip("Set SPEAKUP_SERVER, SPEAKUP_TOKEN and SPEAKUP_MIC_FILE to run against a real server.")
        }
        let seconds = environment["SPEAKUP_RECORD_SECONDS"].flatMap(UInt32.init) ?? 15

        app = XCUIApplication()
        app.launchArguments = [
            "-resetState", "-debug.useMockServer", "NO", "-debug.microphoneFile", micFile,
            "-serverAddress", server,
        ]
        app.launch()

        enterToken(token)
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        shot("real-01-home")

        // Take 1.
        app.buttons["start.prepared"].tap()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Why we picked Postgres for billing")
        if app.buttons["hideKeyboard"].exists { app.buttons["hideKeyboard"].tap() }
        app.buttons["Record"].tap()
        record(seconds: seconds)
        waitForReport(attempt: 1)
        shot("real-02-report-take1")

        // Take 2 and the comparison.
        app.buttons["Retry"].tap()
        record(seconds: seconds)
        waitForReport(attempt: 2)
        shot("real-03-report-take2")
        let card = app.buttons["report.comparison"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        XCTAssertTrue(app.navigationBars["Comparison"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Take 2 against take 1"].waitForExistence(timeout: 30))
        shot("real-04-comparison")
    }

    // MARK: Steps

    /// Saves the token in Settings, which opens by itself on a fresh install.
    private func enterToken(_ token: String) {
        let settings = app.navigationBars["Settings"]
        if !settings.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
            app.buttons["Settings"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        for label in ["Add token", "Replace"] where app.buttons[label].exists {
            app.buttons[label].tap()
        }
        let field = app.secureTextFields["Token"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(token)
        app.buttons["Test connection"].tap()
        XCTAssertTrue(app.staticTexts["The server answered"].waitForExistence(timeout: 15))
        shot("real-00-settings")
        settings.buttons["Done"].tap()
    }

    private func record(seconds: UInt32) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Recording did not start")
        sleep(seconds)
        done.tap()
    }

    /// Real transcription is slower than the mock, and the first take loads the models.
    private func waitForReport(attempt: Int) {
        if !app.navigationBars["Take \(attempt)"].waitForExistence(timeout: 180) {
            shot("real-debug-no-report-\(attempt)")
            XCTFail("No report for take \(attempt)")
        }
        sleep(1)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? png.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }
}

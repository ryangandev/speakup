import XCTest

/// Walks every home-mode screen against the debug mock server and screenshots each one.
///
/// Run it with the `SpeakUpUITests` scheme. Screenshots are attached to the result bundle;
/// set `TEST_RUNNER_SHOT_DIR` to also write them as PNGs, and `TEST_RUNNER_SHOT_SUFFIX` to
/// tell runs apart (for example one run per appearance and Dynamic Type size).
@MainActor
final class WalkthroughTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "-debug.useMockServer", "YES", "-debug.mockScenario", scenario, "-resetState",
            "-debug.syntheticMicrophone",
        ] + extra
        app.launch()
    }

    // MARK: Flows

    /// Prepared and impromptu, end to end: record, process, report, retry, comparison,
    /// history and settings.
    func testPracticeLoop() throws {
        launch("normal")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        shot("01-home-empty")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let test = app.buttons["Test connection"]
        if test.exists {
            test.tap()
            _ = app.staticTexts["The server answered"].waitForExistence(timeout: 5)
        }
        shot("02-settings")
        app.swipeUp()
        shot("02-settings-bottom")
        app.navigationBars["Settings"].buttons["Done"].tap()

        // Prepared.
        app.buttons["start.prepared"].tap()
        XCTAssertTrue(app.buttons["3 of 5"].waitForExistence(timeout: 5))
        shot("03-nervousness-before")
        app.buttons["3 of 5"].tap()

        XCTAssertTrue(app.navigationBars["Prepared"].waitForExistence(timeout: 5))
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Why we picked Postgres for billing")
        let notes = app.textViews.firstMatch
        if notes.exists {
            notes.tap()
            notes.typeText("Joins for reporting. Team knows it. Cost.")
        }
        dismissKeyboard()
        shot("04-prepared")
        app.buttons["Record"].tap()

        record(shotName: "05-recording", showNotes: true)
        waitForProcessing(shotName: "06-processing")
        waitForReport(attempt: 1)
        shootScrolling("07-report-take1")
        openTranscriptMark()

        // Retry and compare.
        app.buttons["Retry"].tap()
        record(shotName: nil)
        waitForReport(attempt: 2)
        shot("09-report-take2")
        let card = app.buttons["report.comparison"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars["Comparison"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Take 2 against take 1"].waitForExistence(timeout: 10))
        shootScrolling("10-comparison")

        // Next prompt, then impromptu.
        app.navigationBars["Comparison"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Next prompt"].waitForExistence(timeout: 5))
        app.buttons["Next prompt"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
        shootScrolling("11-home-session")

        app.buttons["start.impromptu"].tap()
        XCTAssertTrue(app.navigationBars["Impromptu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Another question"].waitForExistence(timeout: 10))
        shot("12-impromptu")
        app.buttons["Another question"].tap()
        sleep(1)
        let decision = app.buttons["Decision"]
        if decision.exists {
            decision.tap()
            XCTAssertTrue(app.buttons["Another question"].waitForExistence(timeout: 10))
        }
        shot("12-impromptu-category")
        app.buttons["Record"].tap()
        record(shotName: "13-recording-impromptu")
        waitForReport(attempt: 1)
        shot("14-report-impromptu")

        // End the session from the report.
        app.buttons["End session"].tap()
        XCTAssertTrue(app.buttons["2 of 5"].waitForExistence(timeout: 5))
        shot("15-nervousness-after")
        app.buttons["2 of 5"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
        shot("16-home-after-session")

        // History.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        sleep(1)
        shootScrolling("17-history")
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Session"].waitForExistence(timeout: 5))
        sleep(1)
        shootScrolling("18-session-detail")
        let take = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Take 2'")).firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 5))
        take.tap()
        waitForReport(attempt: 2)
        shot("19-report-from-history")
        XCTAssertFalse(app.buttons["Retry"].exists, "History reports have no practice actions")
    }

    /// No Anthropic key: the report has no coaching; once coaching is on, Get coaching fills it in.
    func testNoCoachingThenGetCoaching() throws {
        launch("coachingUnavailable")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        shot("20-home-no-coaching")
        startPrepared(title: "Quarterly roadmap update")
        record(shotName: nil)
        waitForReport(attempt: 1)
        XCTAssertTrue(app.staticTexts["Coaching is off because the server has no Anthropic API key."]
            .waitForExistence(timeout: 5))
        shootScrolling("21-report-no-coaching")

        // Turn coaching on in the mock, then come back to the report.
        app.swipeDown()
        app.swipeDown()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scenario'")).firstMatch.tap()
        app.buttons["Normal"].firstMatch.tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        waitForServer()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Take 1'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let get = app.buttons["Get coaching"]
        XCTAssertTrue(get.waitForExistence(timeout: 10))
        shot("22-report-get-coaching")
        get.tap()
        XCTAssertTrue(app.staticTexts["Verdict"].waitForExistence(timeout: 20))
        shot("23-report-coached-later")
    }

    func testCoachingFails() throws {
        launch("coachingFailed")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        startPrepared(title: "Incident review")
        record(shotName: nil)
        waitForReport(attempt: 1)
        XCTAssertTrue(app.buttons["Try coaching again"].waitForExistence(timeout: 5))
        shot("24-report-coaching-failed")
    }

    func testNoSpeech() throws {
        launch("noSpeech")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        startPrepared(title: "Stand-up")
        record(shotName: nil)
        XCTAssertTrue(app.buttons["Record again"].waitForExistence(timeout: 20))
        shot("25-processing-no-speech")
    }

    func testProcessingFails() throws {
        launch("processingFails")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        startPrepared(title: "Stand-up")
        record(shotName: nil)
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 20))
        shot("26-processing-failed")
    }

    func testUploadFails() throws {
        launch("uploadFails")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        startPrepared(title: "Stand-up")
        record(shotName: nil)
        XCTAssertTrue(app.buttons["Retry upload"].waitForExistence(timeout: 20))
        shot("27-upload-failed")
        app.buttons["Back to Home"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
        shootScrolling("28-home-not-uploaded")
    }

    func testSlowProcessing() throws {
        launch("slowProcessing", extra: ["-slowAfter", "3"])
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        waitForServer()
        startPrepared(title: "Stand-up")
        record(shotName: nil)
        XCTAssertTrue(app.staticTexts["Taking longer than usual"].waitForExistence(timeout: 20))
        shot("29-processing-slow")
        app.buttons["Back to Home"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
        shootScrolling("30-home-processing")
    }

    func testUnreachable() throws {
        launch("unreachable")
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 10))
        sleep(2)
        shot("31-home-unreachable")
        app.buttons["start.impromptu"].tap()
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.navigationBars["Impromptu"].waitForExistence(timeout: 5))
        sleep(2)
        shot("32-impromptu-unreachable")
        app.navigationBars["Impromptu"].buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        sleep(2)
        shot("33-history-unreachable")
    }

    // MARK: Steps

    private func waitForServer() {
        let checking = app.staticTexts["Checking the server"]
        let deadline = Date().addingTimeInterval(5)
        while checking.exists, Date() < deadline { usleep(200_000) }
    }

    private func startPrepared(title text: String) {
        app.buttons["start.prepared"].tap()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()
        let title = app.textFields.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(text)
        dismissKeyboard()
        app.buttons["Record"].tap()
    }

    /// Records a couple of seconds, then taps Done.
    private func record(shotName: String?, showNotes: Bool = false) {
        let done = app.buttons["Done"]
        if !done.waitForExistence(timeout: 10) {
            shot("debug-recording-did-not-start")
            XCTFail("Recording did not start")
            return
        }
        sleep(2)
        if let shotName { shot(shotName) }
        if showNotes, app.buttons["Show notes"].exists {
            app.buttons["Show notes"].tap()
            if let shotName { shot("\(shotName)-notes") }
        }
        done.tap()
    }

    private func waitForProcessing(shotName: String) {
        XCTAssertTrue(app.buttons["Back to Home"].waitForExistence(timeout: 10))
        sleep(1)
        shot(shotName)
    }

    private func waitForReport(attempt: Int) {
        if !app.navigationBars["Take \(attempt)"].waitForExistence(timeout: 30) {
            shot("debug-no-report-\(attempt)")
            XCTFail("No report for take \(attempt)")
            return
        }
        sleep(1)
    }

    private func openTranscriptMark() {
        let marked = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Filler'")).firstMatch
        guard marked.exists else { return }
        if !marked.isHittable {
            app.swipeUp()
        }
        marked.tap()
        sleep(1)
        shot("08-transcript-mark")
        // Tap above the sheet to close it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        sleep(1)
        // Back to the top for the retry button and later steps.
        for _ in 0..<6 { app.swipeDown() }
    }

    private func dismissKeyboard() {
        let hide = app.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
        sleep(1)
    }

    // MARK: Screenshots

    /// Screenshots the screen, then scrolls a page at a time until the content stops moving.
    private func shootScrolling(_ name: String, maxPages: Int = 8) {
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        shot(name, data: previous)
        for page in 2...maxPages {
            app.swipeUp()
            usleep(600_000)
            let current = XCUIScreen.main.screenshot().pngRepresentation
            if current == previous { break }
            shot("\(name)-p\(page)", data: current)
            previous = current
        }
        for _ in 0..<maxPages { app.swipeDown() }
    }

    private func shot(_ name: String, data: Data? = nil) {
        let png = data ?? XCUIScreen.main.screenshot().pngRepresentation
        let environment = ProcessInfo.processInfo.environment
        let suffix = environment["SHOT_SUFFIX"].map { "-\($0)" } ?? ""
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["SHOT_DIR"] {
            let url = URL(filePath: directory).appending(path: "\(name)\(suffix).png")
            try? png.write(to: url)
        }
    }
}

import XCTest

/// Drives against the debug mock server, with a scripted recognizer and the scripted
/// microphone, since the simulator has neither a recognizer nor real input. Speech is instant
/// and logged, so the tests read what the drive said from `drive.spokenLog`.
///
/// These prove the wiring from the Home card to the server and back to the screen;
/// `DriveLoopTests` covers each transition of the loop.
///
/// Set `TEST_RUNNER_SHOT_DIR` to also write the screenshots as PNGs, and
/// `TEST_RUNNER_SHOT_SUFFIX` to tell runs apart.
@MainActor
final class DriveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Every command: a rating, an answer, "again", a second answer, "read the better
    /// version", "repeat that", "next", a third answer on a new question, "stop", the
    /// after-rating.
    func testAFullDriveFromTheHomeCard() throws {
        launch(
            scenario: "normal",
            betweenTakes: ["three@0.5", "again@0.5", "read the better version@0.5", "repeat that@0.5", "next@0.5",
                "stop@0.5", "two@0.5"],
            recording: ["so that is my answer@0.5 done@3", "this time it is clearer@0.5 done@3",
                "a new answer@0.5 done@3"])

        let card = app.buttons["start.drive"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        shot("drive-01-home-card")
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["drive.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Stop drive"].exists)

        let log = waitForTheEnd(timeout: 120)
        shot("drive-05-summary")
        expect(log, says: [
            "SpeakUp drive. How nervous are you, one to five?",
            "Nervousness three.",
            "What worked:",
            "Next time:",
            "Here is a better version.",
            "How nervous are you now, one to five?",
            "Nervousness two.",
            "Drive ended. 3 answers saved.",
        ])
        XCTAssertEqual(count("tone: start recording", in: log), 3, log)
        XCTAssertEqual(count("say: Got it.", in: log), 3, log)
        // Feedback on three answers, and "repeat that" says the second answer's again. The mock
        // gives a retry its own focus item.
        XCTAssertEqual(count("say: Next time:", in: log), 4, log)
        XCTAssertEqual(count("say: Next time: Close on purpose.", in: log), 2, log)

        // "again" asks the same question; "next" asks another.
        let questions = spokenLines(in: log).filter { $0.hasSuffix("Answer after the tone.") }
        XCTAssertEqual(questions.count, 3, log)
        XCTAssertEqual(questions[1], "Same question. " + questions[0])
        XCTAssertNotEqual(questions[2], questions[0])

        expectSummary(saved: 3, later: 0)
        app.buttons["Done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop drive"].exists)
    }

    /// The server has no coaching: the drive speaks the metrics instead.
    func testADriveWithoutCoachingSpeaksTheMetrics() throws {
        launch(
            scenario: "coachingUnavailable", betweenTakes: ["three@0.5", "stop@0.5", "skip@0.5"],
            recording: ["so that is my answer@0.5 done@3"])
        app.buttons["start.drive"].tap()

        let log = waitForTheEnd(timeout: 60)
        expect(log, says: ["No coaching right now.", "words per minute", "Skipped.", "Drive ended. One answer saved."])
        XCTAssertFalse(log.contains("What worked:"), log)
        expectSummary(saved: 1, later: 0)
    }

    /// No server: each answer is kept on the phone, the drive says so and goes on to the next
    /// question, and Home lists the answers as waiting to upload once the drive ends.
    func testAnOfflineDriveKeepsItsAnswers() throws {
        launch(
            scenario: "unreachable", betweenTakes: ["three@0.5", "next@0.5", "stop@0.5", "skip@0.5"],
            recording: ["so that is my answer@0.5 done@3", "a new answer@0.5 done@3"])
        app.buttons["start.drive"].tap()

        let log = waitForTheEnd(timeout: 60)
        XCTAssertEqual(
            count("I couldn't reach the server. Your answer is saved; feedback will come later.", in: log), 2, log)
        let questions = spokenLines(in: log).filter { $0.hasSuffix("Answer after the tone.") }
        XCTAssertEqual(questions.count, 2, log)
        XCTAssertNotEqual(questions[0], questions[1])
        expect(log, says: ["Drive ended. 2 answers saved."])
        expectSummary(saved: 2, later: 2)
        shot("drive-06-offline-summary")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Waiting to upload"].waitForExistence(timeout: 5))
        shot("drive-07-offline-home")
    }

    /// Siri starts a drive while Home's nervousness sheet is up: the drive's screen still
    /// shows, and the sheet does not come back after it.
    func testADriveStartedOverASheet() throws {
        launch(scenario: "normal", betweenTakes: ["three@0.5"], recording: [], extra: ["-debug.startDrive", "6"])

        app.buttons["Settings"].tap()
        let sheet = app.navigationBars["Settings"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        let status = app.descendants(matching: .any)["drive.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
        // The sheet leaves with the tabs, after its own dismissal animation.
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        shot("drive-over-sheet")

        app.buttons["Stop drive"].tap()
        XCTAssertTrue(app.staticTexts["Drive ended"].waitForExistence(timeout: 20), spoken())
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["start.drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Practice"].isSelected)
        XCTAssertFalse(sheet.exists)
    }

    // MARK: Steps

    private func launch(scenario: String, betweenTakes: [String], recording: [String], extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments =
            [
                "-debug.useMockServer", "YES", "-debug.mockScenario", scenario, "-resetState", "-showsDriving", "YES",
                "-debug.syntheticMicrophone", "-debug.instantSpeech", "-debug.speechLog",
                "-debug.recognizerScript", Self.script(betweenTakes: betweenTakes, recording: recording),
            ] + extra
        app.launch()
    }

    /// The recognizer script as one line: a launch argument with a line break does not reach
    /// the app whole.
    private static func script(betweenTakes: [String], recording: [String]) -> String {
        let json = ["betweenTakes": betweenTakes, "recording": recording]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the summary and returns everything the drive said.
    private func waitForTheEnd(timeout: TimeInterval) -> String {
        let ended = app.staticTexts["Drive ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: timeout), "the drive did not end; it said:\n\(spoken())")
        return spoken()
    }

    private func expect(_ log: String, says lines: [String]) {
        for line in lines {
            XCTAssertTrue(log.contains(line), "missing \"\(line)\" in:\n\(log)")
        }
    }

    private func expectSummary(saved: Int, later: Int) {
        let savedRow = app.descendants(matching: .any)["drive.summary.saved"]
        XCTAssertTrue(savedRow.exists)
        XCTAssertTrue(savedRow.label.hasSuffix("\(saved)"), "the summary says \(savedRow.label)")
        let laterRow = app.descendants(matching: .any)["drive.summary.later"]
        XCTAssertTrue(laterRow.label.contains("\(later)"), "the summary says \(laterRow.label)")
    }

    private func count(_ text: String, in log: String) -> Int {
        log.components(separatedBy: text).count - 1
    }

    /// The text of each `say:` line, without its time.
    private func spokenLines(in log: String) -> [String] {
        log.split(separator: "\n").compactMap { line in
            line.range(of: " say: ").map { String(line[$0.upperBound...]) }
        }
    }

    /// Every line the drive said, from the Debug-only `drive.spokenLog` element.
    private func spoken() -> String {
        app.descendants(matching: .any)["drive.spokenLog"].value as? String ?? ""
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let environment = ProcessInfo.processInfo.environment
        let suffix = environment["SHOT_SUFFIX"].map { "-\($0)" } ?? ""
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["SHOT_DIR"] {
            try? png.write(to: URL(filePath: directory).appending(path: "\(name)\(suffix).png"))
        }
    }
}

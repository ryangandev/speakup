import XCTest

/// A drive from the Home card, against the debug mock server, with a scripted recognizer and
/// the scripted microphone, since the simulator has neither a recognizer nor real input.
/// Speech is instant and logged, so the test reads what the drive said from `drive.spokenLog`.
///
/// Set `TEST_RUNNER_SHOT_DIR` to also write the screenshots as PNGs, and
/// `TEST_RUNNER_SHOT_SUFFIX` to tell runs apart.
@MainActor
final class DriveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Rating, an answer, "again", a second answer, "stop", the after-rating.
    func testADriveFromTheHomeCard() throws {
        // One line: a launch argument with a line break does not reach the app whole.
        let script =
            #"{"betweenTakes": ["three@0.5", "again@0.5", "stop@0.5", "two@0.5"], "#
            + #""recording": ["so that is my answer@0.5 done@3", "this time it is clearer@0.5 done@3"]}"#
        app = XCUIApplication()
        app.launchArguments = [
            "-debug.useMockServer", "YES", "-debug.mockScenario", "normal", "-resetState",
            "-debug.syntheticMicrophone", "-debug.instantSpeech", "-debug.speechLog",
            "-debug.recognizerScript", script,
        ]
        app.launch()

        let card = app.buttons["start.drive"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        shot("drive-01-home-card")
        card.tap()

        let status = app.descendants(matching: .any)["drive.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Stop drive"].exists)

        let ended = app.staticTexts["Drive ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: 90), "the drive did not end; it said:\n\(spoken())")
        shot("drive-05-summary")

        let log = spoken()
        for line in [
            "say: SpeakUp drive. How nervous are you, one to five?",
            "say: Nervousness three.",
            "tone: start recording",
            "say: Got it.",
            "say: What worked:",
            "say: Next time:",
            "say: Same question.",
            "say: How nervous are you now, one to five?",
            "say: Nervousness two.",
            "say: Drive ended. 2 answers saved.",
        ] {
            XCTAssertTrue(log.contains(line), "missing \"\(line)\" in:\n\(log)")
        }
        XCTAssertEqual(log.components(separatedBy: "say: Got it.").count - 1, 2)

        let saved = app.descendants(matching: .any)["drive.summary.saved"]
        XCTAssertTrue(saved.exists)
        XCTAssertTrue(saved.label.contains("2"), "the summary says \(saved.label)")
        let later = app.descendants(matching: .any)["drive.summary.later"]
        XCTAssertTrue(later.label.contains("0"), "the summary says \(later.label)")

        app.buttons["Done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop drive"].exists)
    }

    /// Siri starts a drive while Home's nervousness sheet is up: the drive's screen still
    /// shows, and the sheet does not come back after it.
    func testADriveStartedOverASheet() throws {
        app = XCUIApplication()
        app.launchArguments = [
            "-debug.useMockServer", "YES", "-debug.mockScenario", "normal", "-resetState",
            "-debug.syntheticMicrophone", "-debug.instantSpeech", "-debug.speechLog",
            "-debug.startDrive", "6",
            "-debug.recognizerScript", #"{"betweenTakes": ["three@0.5"], "recording": []}"#,
        ]
        app.launch()

        app.buttons["start.prepared"].tap()
        let sheet = app.buttons["3 of 5"]
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

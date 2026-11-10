import AVFoundation
import XCTest

/// One drive against a real analysis server: a rating, an answer from the file microphone
/// that ends in a spoken "done", its feedback, "again", a second answer, "stop".
///
/// It checks what the server got: takes cut at "done" (shorter than the clip, so neither the
/// command nor the silence after it is in them), and the second take a retry of the first.
/// The recognizer is scripted, since the simulator has none; the audio is real speech.
///
/// It is skipped unless the `RealServerTests` variables are set, plus:
///
/// - `SPEAKUP_DRIVE_SCRIPT`: when the words of the `SPEAKUP_MIC_FILE` clip are said, as one
///   recognizer script line, for example `so we chose postgres@0.5 done@12.1`. The clip must
///   end in a spoken "done" at that time, after a pause of a second or more, and some silence.
///
/// `say` makes such a clip, with `[[slnc 1000]]` for each pause; see ios/AGENTS.md.
@MainActor
final class DriveRealServerTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testADriveAgainstRealServer() async throws {
        let server = try RealServer.fromEnvironment()
        guard let answer = ProcessInfo.processInfo.environment["SPEAKUP_DRIVE_SCRIPT"] else {
            throw XCTSkip("Set SPEAKUP_DRIVE_SCRIPT to the words of SPEAKUP_MIC_FILE, ending in done@<seconds>.")
        }
        let doneAt = try XCTUnwrap(
            answer.split(separator: " ").last { $0.hasPrefix("done@") }.flatMap { Double($0.dropFirst(5)) },
            "SPEAKUP_DRIVE_SCRIPT has no done@<seconds>")
        let clip = try AVAudioFile(forReading: URL(filePath: server.micFile))
        let clipSeconds = Double(clip.length) / clip.processingFormat.sampleRate

        let script = try JSONSerialization.data(
            withJSONObject: ["betweenTakes": ["three@0.5", "again@0.5", "stop@0.5", "two@0.5"], "recording": [answer, answer]],
            options: [.sortedKeys])
        app = XCUIApplication()
        app.launchArguments = [
            "-resetState", "-showsDriving", "YES", "-debug.useMockServer", "NO", "-debug.microphoneFile", server.micFile,
            "-serverAddress", server.address, "-debug.instantSpeech", "-debug.speechLog",
            "-debug.recognizerScript", String(decoding: script, as: UTF8.self),
        ]
        app.launch()
        app.saveServerToken(server.token)

        let card = app.buttons["start.drive"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        // Two real transcriptions; the first loads the models. The drive itself gives up
        // waiting on one after 120 s.
        let ended = app.staticTexts["Drive ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: 400), "the drive did not end; it said:\n\(spoken())")
        shot("real-drive-summary")

        let log = spoken()
        print("The drive said:\n\(log)")
        XCTAssertEqual(log.components(separatedBy: "tone: start recording").count - 1, 2, log)
        XCTAssertTrue(log.contains("say: Same question."), log)
        XCTAssertTrue(log.contains("Drive ended. 2 answers saved."), log)
        // Feedback on both answers: coaching when the server has a key, metrics without one.
        let feedback = log.components(separatedBy: "say: No coaching right now.").count - 1
            + log.components(separatedBy: "Next time:").count - 1
        XCTAssertEqual(feedback, 2, log)

        // What the server got.
        let sessions = try await server.get("/v1/sessions?limit=1")
        let sessionID = try XCTUnwrap((sessions["sessions"] as? [[String: Any]])?.first?["id"] as? String)
        let session = try await server.get("/v1/sessions/\(sessionID)")
        XCTAssertEqual(session["mode"] as? String, "driving")
        let prompts = try XCTUnwrap(session["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.count, 1, "\"again\" keeps the same prompt")
        let takes = try XCTUnwrap(prompts.first?["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.map { $0["attempt"] as? Int }, [1, 2])
        XCTAssertEqual(takes[1]["previous_take_id"] as? String, takes[0]["id"] as? String)
        for take in takes {
            let duration = try XCTUnwrap(take["duration_s"] as? Double)
            print("Take \(take["attempt"] ?? "?"): duration_s \(duration), clip \(clipSeconds) s, done at \(doneAt) s")
            // Cut 0.1 s before "done": the command and the silence after it are not sent.
            XCTAssertLessThan(duration, doneAt)
            XCTAssertGreaterThan(duration, doneAt - 1)
            XCTAssertLessThan(duration, clipSeconds - 1)
        }
    }

    /// Every line the drive said, from the Debug-only `drive.spokenLog` element.
    private func spoken() -> String {
        app.descendants(matching: .any)["drive.spokenLog"].value as? String ?? ""
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

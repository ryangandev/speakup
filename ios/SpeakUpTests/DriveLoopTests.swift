import Foundation
import Testing
@testable import SpeakUp

/// A drive end to end with fakes for the audio, the recognizer, speech and the server, on a
/// clock that only moves when nothing else can happen.
@MainActor
final class DriveHarness {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "drive-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store: PracticeStore
    let server = DriveServer()
    let audio = FakeDriveAudio()
    let recognizer = FakeRecognizer()
    let speech = FakeSpeech()
    let clock = ManualDriveClock()
    let loop: DriveLoop

    init(config: DriveLoop.Config = .init(), betweenTakes: [String?], recording: [String?]) {
        store = PracticeStore(directory: directory)
        let api = server.api
        let sync = TakeSync(store: store, api: { api }, inBackground: { _, work in try await work() })
        recognizer.lines = [.betweenTakes: betweenTakes, .recording: recording]
        audio.onFlush = { [speech] in speech.flush() }
        loop = DriveLoop(
            audio: audio, recognizer: recognizer, speech: speech, store: store, sync: sync, api: { api },
            questions: DriveQuestions(fileURL: nil, api: { api }), clock: clock, config: config)
    }

    var said: [String] { speech.said }
    /// The drive's session on the phone. Once the server has all of it, the phone drops it, so
    /// after a drive a test checks `created`, `ended` and `server.uploaded` instead.
    var session: LocalSession? { loop.sessionID.flatMap { store.session(id: $0) } }
    var created: SessionCreateRequest? { loop.sessionID.flatMap { server.createdSessions[$0] } }
    var ended: SessionEndRequest? { loop.sessionID.flatMap { server.endedSessions[$0] } }
    /// The id of every take opened, from its file name.
    var takeIDs: [String] { audio.opened.map { $0.url.deletingPathExtension().lastPathComponent } }

    func count(_ line: String) -> Int { said.filter { $0 == line }.count }
    /// How many start tones were played.
    var startTones: Int { speech.log.filter { $0 == "tone: start recording" }.count }

    /// What has visibly happened so far; while it changes, the drive is still busy.
    private var progress: String {
        "\(loop.state) \(speech.log.count) \(server.api.calls.count) \(audio.opened.count) \(audio.finished.count) \(recognizer.listens.count)"
    }

    /// Runs the drive until `condition`, moving the clock only when the drive is waiting on it:
    /// nothing has moved in a whole settle. A drive with nothing to wake and nothing moving for
    /// a few seconds has stalled.
    @discardableResult
    func run(until condition: () -> Bool) async -> Bool {
        var stillRounds = 0
        while true {
            let before = progress
            await settle()
            if condition() { return true }
            if progress != before || (clock.now < 24 * 3600 && clock.advanceToNextWake()) {
                stillRounds = 0
                continue
            }
            stillRounds += 1
            if stillRounds > 500 {
                Issue.record("The drive stalled in \(loop.state) at \(clock.now) s")
                return false
            }
        }
    }

    /// Starts the drive and runs it to its end, background sync included.
    func runToEnd() async {
        if loop.state == .idle { loop.start() }
        guard await run(until: { if case .ended = loop.state { true } else { false } }) else { return }
        await loop.finished()
        await loop.syncTask?.value
    }

    func start(until condition: () -> Bool) async {
        loop.start()
        await run(until: condition)
    }

    /// Lets every task that can run, run: the loop, the recognizer's stream and the fake server.
    func settle() async {
        for _ in 0..<4 {
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The drive time a take opened at: 0.2 s after the speech and tones before it.
    func takeStart(_ index: Int) -> TimeInterval {
        var tones = 0
        for (position, entry) in speech.log.enumerated() where entry == "tone: start recording" {
            if tones == index { return Double(position + 1) + 0.2 }
            tones += 1
        }
        return -1
    }
}

@MainActor
struct DriveLoopTests {
    private let firstFeedback = [
        "You named the decision in the first sentence, which is right, but your reasons came out as one long run and the answer trailed off at the end. Clear enough to follow, not yet crisp.",
        "What worked: You said what was chosen before explaining anything, so the listener knew where you were going.",
    ]
    private let coachedOptions = "Say: again, next, repeat that, better version, or stop."
    private let retrySummary = "The reasons are now numbered and the long block is gone; the ending still trails off."

    // MARK: - The full loop

    @Test func aFullLoopRetriesTheSamePromptAsTheNextAttempt() async throws {
        let drive = DriveHarness(betweenTakes: ["three", "again", "stop", "two"], recording: ["done", "done"])
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stopped))
        let created = try #require(drive.created)
        #expect(created.mode == .driving)
        #expect(created.nervousnessBefore == 3)
        #expect(drive.ended?.nervousnessAfter == 2)

        // Two takes of one prompt: attempt 1, then the retry as attempt 2 of the same prompt,
        // uploaded with the ids the phone gave them.
        #expect(drive.server.createdPrompts.count == 1)
        let (promptID, prompt) = try #require(drive.server.createdPrompts.first)
        #expect(prompt.kind == .impromptu)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.server.uploaded.map(\.metadata.attempt) == [1, 2])
        #expect(drive.server.uploaded.allSatisfy { $0.metadata.promptId == promptID })

        let read = DriveScript.promptReadOut(question: prompt.text)
        let reread = DriveScript.promptReadOut(question: prompt.text, isRetry: true)
        #expect(Array(drive.said.prefix(3)) == [DriveScript.opening, "Nervousness three.", read])
        #expect(drive.said.contains(reread))
        #expect(drive.count(DriveScript.takeEnded) == 2)
        // Take 1: verdict, strength, focus. The retry leads with what changed.
        #expect(drive.said.contains(firstFeedback[0]))
        #expect(drive.said.contains(firstFeedback[1]))
        #expect(drive.said.contains(retrySummary))
        #expect(drive.said.contains { $0.hasPrefix("Next time: Number your reasons.") })
        #expect(drive.count(coachedOptions) == 2)
        #expect(Array(drive.said.suffix(3)) == [
            DriveScript.nervousnessAfterQuestion, "Nervousness two.", DriveScript.driveEnded(takes: 2),
        ])

        // Each take opened 0.2 s after the start tone, and was cut at the start of "done".
        #expect(drive.audio.opened.map(\.start) == [drive.takeStart(0), drive.takeStart(1)])
        #expect(drive.audio.finished.map(\.reason) == [.finished, .finished])
        #expect(drive.audio.finished.map(\.cutAt) == [drive.takeStart(0) + 1, drive.takeStart(1) + 1])
        #expect(drive.recognizer.stopped)
        #expect(!drive.audio.isRunning)
    }

    @Test func nextRepeatBetterVersionAndStop() async throws {
        let drive = DriveHarness(
            betweenTakes: ["skip", "repeat that", "read the better version", "next", "stop", "skip"],
            recording: ["done", "done"])
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stopped))
        #expect(drive.created?.nervousnessBefore == nil)
        #expect(drive.ended != nil)
        #expect(drive.ended?.nervousnessAfter == nil)
        // "next" made a new prompt with a different question, each answered once.
        #expect(Set(drive.server.createdPrompts.values.map(\.text)).count == 2)
        #expect(drive.server.uploaded.map(\.metadata.attempt) == [1, 1])
        #expect(Set(drive.server.uploaded.map(\.metadata.promptId)).count == 2)
        #expect(!drive.said.contains { $0.hasPrefix("Same question.") })

        // "repeat that" says the feedback again; "read the better version" reads the reference.
        #expect(drive.count(firstFeedback[0]) == 3)
        #expect(drive.said.contains("Here is a better version."))
        #expect(drive.said.contains("We chose Postgres for billing. Two reasons."))
        #expect(drive.said.contains("Say: again, next, or stop."))
        #expect(Array(drive.said.suffix(3)) == [
            DriveScript.nervousnessAfterQuestion, "Skipped.", DriveScript.driveEnded(takes: 2),
        ])
    }

    @Test func unrecognizedSpeechGetsTheCommandListOnce() async throws {
        let drive = DriveHarness(
            betweenTakes: ["three", "what was that", "turn left here", "stop", "skip"], recording: ["done"])
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stopped))
        #expect(drive.count(DriveScript.commandHelp) == 1)
    }

    @Test func aRatingIsAskedAgainOnceThenSkipped() async throws {
        let drive = DriveHarness(betweenTakes: ["banana", nil, "stop", "skip"], recording: ["done"])
        await drive.runToEnd()

        #expect(Array(drive.said.prefix(3)) == [DriveScript.opening, DriveScript.nervousnessReask, "Skipped."])
        #expect(drive.created?.nervousnessBefore == nil)
    }

    // MARK: - Feedback

    @Test func withoutCoachingTheMetricsAreSpoken() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "better version", "stop", "skip"], recording: ["done"])
        drive.server.processing = .noCoaching
        await drive.runToEnd()

        #expect(drive.said.contains("No coaching right now."))
        #expect(drive.said.contains("You used about 4 fillers per 100 words."))
        #expect(drive.said.contains("You got stuck mid-phrase twice."))
        #expect(drive.said.contains("You spoke at about 150 words per minute."))
        #expect(!drive.server.api.calls.contains { $0.hasPrefix("report") })
        #expect(drive.said.contains("There is no better version without coaching."))
    }

    @Test func aTakeWithNoSpeechSaysSo() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: ["done"])
        drive.server.processing = .noSpeech
        await drive.runToEnd()

        #expect(drive.said.contains("I didn't catch an answer."))
    }

    @Test func aTakeWithNoAudioIsNotKept() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: ["done"])
        drive.audio.nextEnd = { _, reason in .empty(reason) }
        await drive.runToEnd()

        #expect(drive.store.sessions.allSatisfy { $0.takes.isEmpty })
        #expect(drive.said.contains("I didn't catch an answer."))
        #expect(!drive.said.contains(DriveScript.takeEnded))
        #expect(drive.server.uploaded.isEmpty)
    }

    // MARK: - Offline and slow

    @Test func offlineKeepsTheTakeOffersTheNextPromptAndUploadsLater() async throws {
        let drive = DriveHarness(betweenTakes: ["skip", nil, "stop", "skip"], recording: ["done", "done"])
        drive.server.online = false
        await drive.start { drive.loop.state == .awaitingCommand }

        // The take is on the phone, queued, and the prompt came from the built-in bank.
        let session = try #require(drive.session)
        #expect(session.prompts.first?.questionSource == .bank)
        let first = try #require(session.takes.first)
        #expect(!first.isUploaded)
        #expect(drive.store.pendingUploads.map(\.id) == [first.id])
        #expect(drive.said.contains("I couldn't reach the server. Your answer is saved; feedback will come later."))
        #expect(drive.said.contains("Say: next, again, or stop."))

        // The server comes back; the next prompt sends the waiting take first.
        drive.server.online = true
        drive.recognizer.say("next")
        await drive.runToEnd()

        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.server.uploaded.first?.id == first.id)
        #expect(drive.ended != nil)
    }

    @Test func aRetryReachesTheServerAfterTheOfflineTakeItRetries() async throws {
        let drive = DriveHarness(betweenTakes: ["skip", "again", "stop", "skip"], recording: ["done", nil])
        drive.server.online = false
        await drive.start { drive.loop.state == .recording && drive.audio.opened.count == 2 }
        // Coverage comes back while the retry is being recorded, after the background sync
        // before it gave up.
        drive.server.online = true
        drive.recognizer.say("done")
        await drive.runToEnd()

        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.server.uploaded.map(\.metadata.attempt) == [1, 2])
        // The retry was coached as a retry: what changed leads its feedback.
        #expect(drive.said.contains(retrySummary))
    }

    @Test func waitingGivesUpAfterTwoMinutes() async throws {
        let drive = DriveHarness(betweenTakes: ["4", nil, "skip"], recording: ["done"])
        drive.server.processing = .stuck
        await drive.start { drive.loop.state == .awaitingCommand }

        let take = try #require(drive.session?.takes.first)
        #expect(drive.count(DriveScript.stillWorking) == 2)
        #expect(drive.said.contains(DriveScript.waitTimedOut))
        #expect(drive.loop.feedbackLater == [take.id])
        #expect(drive.clock.now >= 120 && drive.clock.now < 125)
        drive.recognizer.say("stop")
        await drive.runToEnd()
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func aStalledUploadCountsAgainstTheWaitAndCarriesOn() async throws {
        let drive = DriveHarness(betweenTakes: ["4", nil, "skip"], recording: ["done"])
        drive.server.uploadGate.close()
        await drive.start { drive.loop.state == .awaitingCommand }

        // The upload never finished, yet he heard "Still working." and the wait ended on time.
        let take = try #require(drive.session?.takes.first)
        #expect(drive.count(DriveScript.stillWorking) == 2)
        #expect(drive.said.last == DriveScript.waitTimedOut)
        #expect(drive.loop.feedbackLater == [take.id])
        #expect(drive.clock.now >= 120 && drive.clock.now < 125)
        #expect(drive.server.uploadGate.waiting == 1)

        // The upload carries on in the background and lands.
        drive.server.uploadGate.open()
        drive.recognizer.say("stop")
        await drive.runToEnd()
        #expect(drive.server.uploaded.map(\.id) == [take.id])
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func aServerErrorIsNotCalledOffline() async throws {
        let drive = DriveHarness(betweenTakes: ["4", "stop", "skip"], recording: ["done"])
        drive.server.uploadError = .server(
            status: 422, code: "invalid_audio", message: "The audio could not be read.", details: nil)
        await drive.runToEnd()

        #expect(drive.said.contains(DriveScript.serverError.segments[0]))
        #expect(!drive.said.contains(DriveScript.offline.segments[0]))
        #expect(drive.loop.feedbackLater.isEmpty)
        // The take stays on the phone.
        #expect(drive.store.pendingUploads.count == 1)
    }

    @Test func stopDuringTheWaitEndsTheDriveAndKeepsTheTake() async throws {
        let drive = DriveHarness(betweenTakes: ["4"], recording: ["done"])
        drive.server.processing = .stuck
        await drive.start { drive.loop.state == .waiting }

        drive.loop.stop()
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stoppedFromApp))
        #expect(drive.loop.feedbackLater == drive.takeIDs)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.said.last == DriveScript.driveEnded(takes: 1))
    }

    @Test func aCallDuringTheWaitSaysFeedbackComesLater() async throws {
        let drive = DriveHarness(betweenTakes: ["4", nil, "skip"], recording: ["done"])
        drive.server.processing = .stuck
        await drive.start { drive.loop.state == .waiting }

        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        #expect(drive.loop.feedbackLater == drive.takeIDs)
        drive.audio.send(.interruptionEnded(resumed: true))
        await drive.run { drive.loop.state == .awaitingCommand }

        #expect(drive.said.last == DriveScript.waitTimedOut)
        #expect(!drive.said.contains(DriveScript.commandHelp))
        drive.recognizer.say("stop")
        await drive.runToEnd()
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func runningCoachingGetsALittleMoreTime() async throws {
        let drive = DriveHarness(betweenTakes: ["4", "stop", "skip"], recording: ["done"])
        // Coaching is still running at the two-minute limit, and done 15 s later.
        drive.server.processing = .slowCoaching(polls: 90)
        await drive.runToEnd()

        #expect(drive.said.contains(firstFeedback[0]))
        #expect(!drive.said.contains(DriveScript.waitTimedOut))
        #expect(drive.loop.feedbackLater.isEmpty)
    }

    // MARK: - Audio events

    @Test func anInterruptionMidTakeSavesItAndResumes() async throws {
        let drive = DriveHarness(betweenTakes: ["2", "stop", "skip"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTake { .interrupted($0) }
        await drive.run { drive.loop.state == .paused }
        let take = try #require(drive.session?.takes.first)
        #expect(take.attempt == 1)

        drive.audio.send(.interruptionEnded(resumed: true))
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stopped))
        #expect(drive.said.contains(DriveScript.cutOff))
        // No feedback was waited for; the take uploaded in the background.
        #expect(!drive.said.contains(DriveScript.takeEnded))
        #expect(drive.server.uploaded.map(\.id) == [take.id])
        #expect(drive.said.last == DriveScript.driveEnded(takes: 1))
    }

    @Test func anInterruptionThatDoesNotResumeEndsTheDrive() async throws {
        let drive = DriveHarness(betweenTakes: ["2"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTake { .interrupted($0) }
        drive.audio.send(.interruptionEnded(resumed: false))
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.interrupted))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.takeIDs.count == 1)
        #expect(drive.ended != nil)
        #expect(drive.ended?.nervousnessAfter == nil)
        #expect(!drive.said.contains(DriveScript.nervousnessAfterQuestion))
    }

    @Test func aMicrophoneChangeEndsTheTakeWhichGetsFeedback() async throws {
        let drive = DriveHarness(betweenTakes: ["2", "stop", "skip"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTake { .takeEnded($0!) }
        await drive.runToEnd()

        // He hears why the take ended, then its feedback.
        #expect(drive.said.contains(DriveScript.microphoneChanged))
        #expect(!drive.said.contains(DriveScript.takeEnded))
        #expect(drive.said.contains(firstFeedback[0]))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
    }

    @Test func doneWhileTheTakesEventIsStillComingWaitsForIt() async throws {
        let drive = DriveHarness(betweenTakes: ["2", "stop", "skip"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        // The microphone changed and the core is still finishing the file when "done" is heard.
        drive.audio.endTakeLater { .takeEnded($0!) }
        drive.recognizer.say("done")
        await drive.run { drive.loop.state == .finishingTake }
        await drive.settle()
        #expect(drive.loop.state == .finishingTake)
        #expect(drive.session?.takes.isEmpty == true)

        drive.audio.deliverPending()
        await drive.runToEnd()

        #expect(drive.takeIDs.count == 1)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.said.contains(DriveScript.takeEnded))
        #expect(drive.said.contains(firstFeedback[0]))
    }

    @Test func aTakesEventArrivingWhileItIsFinishedIsKeptOnce() async throws {
        let drive = DriveHarness(betweenTakes: ["2", "stop", "skip"], recording: [nil])
        drive.audio.deliversPendingDuringFinish = true
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTakeLater { .takeEnded($0!) }
        drive.recognizer.say("done")
        await drive.runToEnd()

        #expect(drive.audio.pendingEvent == nil)
        #expect(drive.takeIDs.count == 1)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.said.contains(firstFeedback[0]))
    }

    @Test func stopWhileTheTakesEventIsStillComingKeepsIt() async throws {
        let drive = DriveHarness(betweenTakes: ["2"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTakeLater { .takeEnded($0!) }
        drive.loop.stop()
        await drive.settle()
        drive.audio.deliverPending()
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stoppedFromApp))
        #expect(drive.takeIDs.count == 1)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.said.last == DriveScript.driveEnded(takes: 1))
    }

    // MARK: - Calls and cut speech

    @Test func aCallDuringTheRatingAsksItAgainAfterwards() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: ["done"])
        var holds = 1
        drive.speech.hold = { entry in
            guard entry == "say: \(DriveScript.opening)", holds > 0 else { return false }
            holds -= 1
            return true
        }
        await drive.start { drive.speech.isHolding }

        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        #expect(drive.loop.sessionID == nil)
        drive.audio.send(.interruptionEnded(resumed: true))
        await drive.runToEnd()

        #expect(drive.count(DriveScript.opening) == 2)
        #expect(drive.created?.nervousnessBefore == 3)
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func aCallDuringThePromptOpensNoTake() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: [])
        var holds = 1
        drive.speech.hold = { entry in
            guard entry.hasSuffix("Answer after the tone."), holds > 0 else { return false }
            holds -= 1
            return true
        }
        await drive.start { drive.speech.isHolding }

        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        drive.audio.send(.interruptionEnded(resumed: true))
        await drive.runToEnd()

        #expect(drive.audio.opened.isEmpty)
        #expect(drive.said.contains(DriveScript.commandHelp))
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func aCallDuringTheStartToneOpensNoTakeAndPauses() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: [])
        var holds = 1
        drive.speech.hold = { entry in
            guard entry == "tone: start recording", holds > 0 else { return false }
            holds -= 1
            return true
        }
        await drive.start { drive.speech.isHolding }

        // The tone is cut before the call's event arrives: the loop must not read the prompt
        // again into the call, nor give up on the audio.
        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        #expect(drive.audio.opened.isEmpty)
        #expect(drive.startTones == 1)
        drive.audio.send(.interruptionEnded(resumed: true))
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stopped))
        #expect(!drive.said.contains(DriveScript.audioUnstable))
    }

    @Test func aCutPromptOrToneIsReadAgainBeforeTheTakeOpens() async throws {
        let drive = DriveHarness(betweenTakes: ["3", "stop", "skip"], recording: ["done"])
        var cuts = ["prompt", "tone"]
        drive.speech.cut = { entry in
            if cuts.first == "prompt", entry.hasSuffix("Answer after the tone.") {
                cuts.removeFirst()
                return true
            }
            if cuts.first == "tone", entry == "tone: start recording" {
                cuts.removeFirst()
                return true
            }
            return false
        }
        await drive.runToEnd()

        let readOuts = drive.said.filter { $0.hasSuffix("Answer after the tone.") }
        #expect(readOuts.count == 3)
        #expect(Set(readOuts).count == 1)
        #expect(drive.startTones == 2)
        #expect(drive.audio.opened.count == 1)
        // The take opened after the tone that played in full.
        #expect(drive.audio.opened.first?.start == drive.takeStart(1))
        #expect(drive.said.contains(firstFeedback[0]))
    }

    @Test func speechCutOffEveryTimeEndsTheDrive() async throws {
        let drive = DriveHarness(betweenTakes: ["3"], recording: [])
        drive.speech.cut = { $0 == "tone: start recording" }
        await drive.runToEnd()

        #expect(drive.audio.opened.isEmpty)
        #expect(drive.startTones == 3)
        #expect(drive.said.contains(DriveScript.audioUnstable))
        if case .ended(.audioFailed) = drive.loop.state {} else {
            Issue.record("The drive ended as \(drive.loop.state)")
        }
        #expect(drive.said.last == DriveScript.driveEnded(takes: 0))
    }

    @Test func stopWhilePausedKeepsTheTakeAndEnds() async throws {
        let drive = DriveHarness(betweenTakes: ["2"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        drive.loop.stop()
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stoppedFromApp))
        #expect(drive.takeIDs.count == 1)
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.said.last == DriveScript.driveEnded(takes: 1))
    }

    @Test func aPauseWithNoEndTakesTheAudioBackAfterThreeMinutes() async throws {
        let drive = DriveHarness(betweenTakes: ["2", "stop", "skip"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.interrupt()
        await drive.run { drive.loop.state == .paused }
        let paused = drive.clock.now
        await drive.runToEnd()

        #expect(drive.audio.resumeAttempts == 1)
        #expect(drive.said.contains(DriveScript.cutOff))
        #expect(drive.clock.now - paused >= 180)
        #expect(drive.loop.state == .ended(.stopped))
    }

    @Test func aPauseWithNoEndEndsTheDriveWhenTheAudioStaysTaken() async throws {
        let drive = DriveHarness(betweenTakes: ["2"], recording: [nil])
        drive.audio.resumes = false
        await drive.start { drive.loop.state == .recording }

        drive.audio.interrupt()
        await drive.runToEnd()

        #expect(drive.audio.resumeAttempts == 1)
        #expect(drive.loop.state == .ended(.interrupted))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.ended != nil)
    }

    @Test func aFailedMicrophoneEndsTheDriveAndKeepsTheTake() async throws {
        let drive = DriveHarness(betweenTakes: ["2"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.audio.endTake { .failed("The engine stopped.", $0) }
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.audioFailed("The engine stopped.")))
        #expect(drive.said.contains(DriveScript.microphoneUnavailable))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.takeIDs.count == 1)
    }

    // MARK: - Commands unavailable, idle, limits, stop

    @Test func commandsUnavailableAtStartEndTheDrive() async throws {
        let drive = DriveHarness(betweenTakes: [], recording: [])
        drive.recognizer.prepareError = CommandRecognizerError.unavailable("No English model.")
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.commandsUnavailable("Voice commands are unavailable: No English model.")))
        #expect(drive.said == [DriveScript.commandsUnavailable, DriveScript.driveEnded(takes: 0)])
        #expect(drive.loop.sessionID == nil)
        #expect(drive.store.sessions.isEmpty)
    }

    @Test func commandsFailingMidTakeKeepTheTakeAndEndTheDrive() async throws {
        let drive = DriveHarness(betweenTakes: ["5"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.recognizer.fail("The speech recognizer stopped.")
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.commandsUnavailable("The speech recognizer stopped.")))
        #expect(Array(drive.said.suffix(2)) == [DriveScript.commandsUnavailable, DriveScript.driveEnded(takes: 1)])
        #expect(drive.audio.finished.map(\.cutAt) == [nil])
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.takeIDs.count == 1)
        #expect(drive.ended != nil)
        #expect(drive.ended?.nervousnessAfter == nil)
    }

    @Test func tenMinutesWithoutACommandEndTheDrive() async throws {
        let drive = DriveHarness(betweenTakes: ["1", nil], recording: ["done"])
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.idle))
        #expect(Array(drive.said.suffix(2)) == [DriveScript.idleEnd, DriveScript.driveEnded(takes: 1)])
        #expect(!drive.said.contains(DriveScript.nervousnessAfterQuestion))
        #expect(drive.clock.now >= 600)
    }

    @Test func aTakeEndsAtTheTimeLimit() async throws {
        let drive = DriveHarness(betweenTakes: ["5", "stop", "skip"], recording: [nil])
        await drive.runToEnd()

        #expect(drive.audio.finished.count == 1)
        #expect(drive.audio.finished.first?.reason == .limit)
        #expect(drive.audio.finished.first?.cutAt == nil)
        #expect(drive.said.contains(DriveScript.timeLimit))
        #expect(!drive.said.contains(DriveScript.takeEnded))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.takeIDs.count == 1)
        #expect(drive.clock.now >= 360)
    }

    @Test func stopFromTheScreenKeepsTheTakeBeingRecorded() async throws {
        let drive = DriveHarness(betweenTakes: ["3"], recording: [nil])
        await drive.start { drive.loop.state == .recording }

        drive.loop.stop()
        await drive.runToEnd()

        #expect(drive.loop.state == .ended(.stoppedFromApp))
        #expect(drive.server.uploaded.map(\.id) == drive.takeIDs)
        #expect(drive.takeIDs.count == 1)
        #expect(drive.said.last == DriveScript.driveEnded(takes: 1))
        #expect(!drive.said.contains(DriveScript.nervousnessAfterQuestion))
    }

    @Test func aDriveClosesASessionLeftOpenAtHome() async throws {
        let drive = DriveHarness(betweenTakes: ["3"], recording: [nil])
        let home = drive.store.openNewSession(mode: .home, nervousnessBefore: 2)
        await drive.start { drive.loop.state == .recording }

        #expect(drive.store.session(id: home.id)?.endedAt == home.startedAt)
        #expect(drive.store.openSession?.id == drive.loop.sessionID)
        #expect(drive.session?.mode == .driving)
        drive.loop.stop()
        await drive.runToEnd()
    }
}

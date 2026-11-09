import Foundation
import Observation
import os

/// The drive loop's sense of time, for its timeouts and waits, so tests can run minutes at once.
///
/// It is not the drive clock (`DriveAudio.now`): that one counts input frames and stands still
/// while a call holds the audio. Speech and recognizer times stay on the drive clock.
protocol DriveLoopClock: Sendable {
    /// Seconds since a fixed point.
    var now: TimeInterval { get }
    /// Returns after `seconds`, or throws when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

/// Real time.
struct SystemDriveLoopClock: DriveLoopClock {
    private let origin = ContinuousClock.now

    var now: TimeInterval { (ContinuousClock.now - origin).timeInterval }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A drive, end to end, with no touch (plan section 2, product.md#driving-mode).
///
/// It runs as one sequence of steps:
///
/// ```text
/// starting ─▶ askingNervousness(before) ─▶ preparingPrompt ─▶ speakingPrompt ─▶ recording
///    ▲                                          ▲                                 │ "done", time limit
///    │                                          │ again / next                    ▼
///    │                                    awaitingCommand ◀── speakingFeedback ◀─ finishingTake
///    │                                     │  ▲     │                    ▲           │ kept
///    │       repeat that, better version ──┘  │     │ stop               └─ waiting ◀─ uploading
///    │                                        │     ▼
///    └─ (interrupted before a session) ─ paused   askingNervousness(after) ─▶ ending ─▶ ended
/// ```
///
/// Anything that happens outside the sequence (a call, a failed microphone, commands that stop
/// working, `stop()` from the screen) is a disruption: the step in progress stops at its next
/// await, and the loop handles the disruption, then resumes at the commands or ends the drive.
///
/// Every take ends with exactly one `DriveAudio.TakeEnd`, from `finishTake` or from an audio
/// event. A kept one goes into the store at once, before anything else happens, so no answer is
/// lost on any path; a take the loop does not wait on is uploaded by `TakeSync.syncPending`.
@MainActor
@Observable
final class DriveLoop {
    enum Rating: Sendable, Equatable {
        case before, after
    }

    enum EndReason: Sendable, Equatable {
        /// "stop" between takes.
        case stopped
        /// `stop()`, from the screen.
        case stoppedFromApp
        /// Nothing was said for `Config.idleLimit`.
        case idle
        /// Every question has been asked in this drive.
        case noQuestions
        /// The drive's session is no longer on the phone (the store was reset).
        case sessionMissing
        case commandsUnavailable(String)
        /// The microphone or the drive's audio failed.
        case audioFailed(String)
        /// A call or Siri took the audio and the drive could not resume.
        case interrupted
    }

    enum State: Sendable, Equatable {
        case idle
        case starting
        case askingNervousness(Rating)
        case preparingPrompt
        case speakingPrompt
        case recording
        /// The take is closed: trimming, the end tone, "Got it."
        case finishingTake
        case uploading
        case waiting
        case speakingFeedback
        case awaitingCommand
        case speakingReference
        /// A call or Siri holds the audio.
        case paused
        case ending
        case ended(EndReason)

        /// From `start()` until the drive has ended.
        var isActive: Bool {
            switch self {
            case .idle, .ended: false
            default: true
            }
        }
    }

    /// Every limit in one place.
    struct Config: Sendable, Equatable {
        /// A take ends here at the latest. Silence never ends one.
        var maxTakeLength: TimeInterval = 6 * 60
        /// The take opens this long after the start tone has played, so neither is in it.
        var takeStartDelay: TimeInterval = 0.2
        /// How long the loop waits for feedback after a take, upload included.
        var waitLimit: TimeInterval = 120
        /// More waiting when the analysis is done but coaching is still running at the limit.
        var coachingGrace: TimeInterval = 30
        /// When "Still working." is said, in seconds into the wait.
        var stillWorkingAt: [TimeInterval] = [30, 60]
        /// The drive ends after this long between takes with no command.
        var idleLimit: TimeInterval = 10 * 60
        /// How long a nervousness question waits for an answer before it asks again.
        var ratingWait: TimeInterval = 15
        /// A prefetch starts when fewer cached questions than this are left.
        var questionsLowWater = 3
    }

    // MARK: What the screen reads

    private(set) var state: State = .idle
    /// The prompt being answered, or the last one answered.
    private(set) var prompt: LocalPrompt?
    /// The drive's session, once the opening question is answered.
    private(set) var sessionID: String?
    /// Takes whose feedback was not ready when waiting gave up. They keep processing and show
    /// in History. This is the seam for late feedback: a later version can poll these and read
    /// `DriveScript.feedback` for them at the next break.
    private(set) var feedbackLater: [String] = []
    #if DEBUG
    /// `-debug.speechLog`: what the drive said, for the Debug-only `drive.spokenLog` element.
    var spokenLog: SpokenLog?
    #endif

    /// How many answers the drive has kept.
    var takesSaved: Int {
        sessionID.flatMap { store.session(id: $0)?.takes.count } ?? 0
    }

    // MARK: Dependencies

    @ObservationIgnored private let audio: any DriveAudioControlling
    @ObservationIgnored private let recognizer: any CommandRecognizing
    @ObservationIgnored private let speech: any SpeechOutputting
    @ObservationIgnored private let store: PracticeStore
    @ObservationIgnored private let sync: TakeSync
    @ObservationIgnored private let api: () -> any SpeakUpAPI
    @ObservationIgnored private let questions: DriveQuestions
    @ObservationIgnored private let clock: any DriveLoopClock
    @ObservationIgnored let config: Config

    // MARK: Loop state

    @ObservationIgnored private var spotter = CommandSpotter()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var recognition: Task<Void, Never>?
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?
    @ObservationIgnored private(set) var questionsTask: Task<Void, Never>?
    /// The take whose gate is open, and the prompt it answers.
    @ObservationIgnored private var openTake: (id: String, promptID: String)?
    /// What was said after the latest take, for "repeat that".
    @ObservationIgnored private var lastFeedback: [String]?
    /// The latest take's report, for "read the better version".
    @ObservationIgnored private var lastReport: TakeReport?
    @ObservationIgnored private var waiting: Waiting?

    @ObservationIgnored private var disruptions: [Disruption] = []
    @ObservationIgnored private var hearWaiter: (ticket: Int, continuation: CheckedContinuation<Heard, Never>)?
    @ObservationIgnored private var hearTicket = 0
    @ObservationIgnored private var finishWaiter: CheckedContinuation<Settled, Never>?
    /// A take the audio core ended while nothing waited for it.
    @ObservationIgnored private var endedTake: Settled?
    @ObservationIgnored private var pauseWaiter: CheckedContinuation<Bool?, Never>?
    /// How the latest interruption ended, when it ended before the loop waited for it.
    @ObservationIgnored private var interruptionEnd: Bool?

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "DriveLoop")

    init(
        audio: any DriveAudioControlling, recognizer: any CommandRecognizing, speech: any SpeechOutputting,
        store: PracticeStore, sync: TakeSync, api: @escaping () -> any SpeakUpAPI, questions: DriveQuestions,
        clock: any DriveLoopClock = SystemDriveLoopClock(), config: Config = Config()
    ) {
        self.audio = audio
        self.recognizer = recognizer
        self.speech = speech
        self.store = store
        self.sync = sync
        self.api = api
        self.questions = questions
        self.clock = clock
        self.config = config
    }

    /// The drive the app runs: the drive engine, its voice, and the recognizer the launch
    /// selects. Call `start()` in the foreground, with microphone permission granted.
    static func live(store: PracticeStore, sync: TakeSync, api: @escaping () -> any SpeakUpAPI) -> DriveLoop {
        let audio = DriveAudio()
        let speech = SpeechOutput(audio: audio)
        let loop = DriveLoop(
            audio: audio, recognizer: CommandRecognizers.makeDefault(), speech: speech, store: store, sync: sync,
            api: api, questions: DriveQuestions(fileURL: DriveQuestions.fileURL(in: store), api: api))
        #if DEBUG
        loop.spokenLog = speech.spokenLog
        #endif
        return loop
    }

    // MARK: Start and stop

    /// Starts the drive. A drive runs once; make a new loop for the next one.
    func start() {
        guard state == .idle else { return }
        state = .starting
        runTask = Task { await run() }
    }

    /// Ends the drive from the screen: an answer being recorded is kept, and there is no
    /// after-rating.
    func stop() {
        guard state.isActive, state != .ending else { return }
        disrupt(.stopTapped)
    }

    /// Returns once the drive has ended.
    func finished() async {
        await runTask?.value
    }

    // MARK: - The sequence

    private enum Step: Equatable {
        case opening
        case prompt(retry: Bool)
        /// Waits for a command, after saying `intro`.
        case commands(intro: String?)
        case end(EndReason, line: String?, askAfter: Bool)
    }

    private func run() async {
        audio.onEvent = { [weak self] event in self?.audioEvent(event) }
        do {
            try await audio.start()
        } catch {
            // Nothing can be said without the drive's audio.
            Self.log.error("The drive's audio did not start: \(error.localizedDescription, privacy: .public)")
            audio.onEvent = nil
            state = .ended(.audioFailed(error.localizedDescription))
            return
        }
        questions.beginDrive()
        prefetchQuestions()
        do {
            try await recognizer.prepare()
            listen(to: try await recognizer.start(buffers: audio.recognizerBuffers()))
        } catch {
            await end(.commandsUnavailable(error.localizedDescription), line: DriveScript.commandsUnavailable, askAfter: false)
            return
        }

        var step = Step.opening
        while true {
            do {
                switch step {
                case .opening:
                    try await opening()
                    step = .prompt(retry: false)
                case .prompt(let retry):
                    step = try await promptAndTake(retry: retry)
                case .commands(let intro):
                    step = try await commands(intro: intro)
                case .end(let reason, let line, let askAfter):
                    await end(reason, line: line, askAfter: askAfter)
                    return
                }
            } catch {
                step = await handleDisruption()
            }
        }
    }

    /// Greeting and the nervousness question, then the drive's session.
    private func opening() async throws {
        try checkpoint()
        state = .askingNervousness(.before)
        let rating = try await askRating(DriveScript.opening)
        // A drive is its own sitting: a session left open at home closes where it stopped.
        if let open = store.openSession {
            store.endSession(open.id, endedAt: open.lastTakeEnd ?? open.startedAt, nervousnessAfter: nil)
        }
        sessionID = store.openNewSession(mode: .driving, nervousnessBefore: rating).id
    }

    /// Asks a nervousness question: a number from one to five, or skip. One re-ask, then skip.
    private func askRating(_ question: String) async throws -> Int? {
        await speech.speak(question)
        try checkpoint()
        for attempt in 0..<2 {
            switch await hear(.betweenTakes, from: speech.outputEnd, timeout: config.ratingWait) {
            case .event(.command(.rating(let value))) where (1...5).contains(value):
                await speech.speak(DriveScript.nervousnessRecorded(value))
                try checkpoint()
                return value
            case .event(.command(.skip)):
                await speech.speak(DriveScript.nervousnessRecorded(nil))
                try checkpoint()
                return nil
            case .aborted:
                try checkpoint()
            default:
                break
            }
            if attempt == 0 {
                await speech.speak(DriveScript.nervousnessReask)
                try checkpoint()
            }
        }
        await speech.speak(DriveScript.nervousnessRecorded(nil))
        try checkpoint()
        return nil
    }

    /// Reads a prompt, records the answer, and gives the feedback.
    private func promptAndTake(retry: Bool) async throws -> Step {
        try checkpoint()
        state = .preparingPrompt
        guard let sessionID else { return .opening }
        if !store.pendingUploads.isEmpty { syncInBackground() }

        let prompt: LocalPrompt
        let isRetry = retry && self.prompt != nil
        if isRetry, let current = self.prompt {
            prompt = current
        } else {
            guard let question = questions.next() else {
                return .end(.noQuestions, line: DriveScript.noQuestions, askAfter: false)
            }
            if questions.cached.count < config.questionsLowWater { prefetchQuestions() }
            guard
                let added = store.addPrompt(
                    sessionID: sessionID, kind: .impromptu, text: question.text, notes: nil,
                    category: question.category, targetSeconds: question.targetSeconds,
                    questionSource: question.source)
            else { return .end(.sessionMissing, line: nil, askAfter: false) }
            prompt = added
        }
        self.prompt = prompt

        state = .speakingPrompt
        await speech.speak(DriveScript.promptReadOut(question: prompt.text, isRetry: isRetry))
        try checkpoint()
        await speech.play(.startRecording)
        try checkpoint()

        let start = speech.outputEnd + config.takeStartDelay
        let takeID = IDs.make()
        do {
            try audio.openTake(url: store.newRecordingURL(takeID: takeID), at: start)
        } catch {
            try checkpoint()
            Self.log.error("No take opened: \(error.localizedDescription, privacy: .public)")
            return .end(.audioFailed(error.localizedDescription), line: DriveScript.microphoneUnavailable, askAfter: false)
        }
        openTake = (takeID, prompt.id)
        state = .recording

        let settled: Settled
        let atLimit: Bool
        let limit = clock.now + config.maxTakeLength
        recording: while true {
            switch await hear(.recording, from: start, timeout: max(0, limit - clock.now)) {
            case .event(.done(let cutAt)):
                state = .finishingTake
                settled = await finishOpenTake(cutAt: cutAt, reason: .finished)
                atLimit = false
            case .timeout:
                state = .finishingTake
                settled = await finishOpenTake(cutAt: nil, reason: .limit)
                atLimit = true
            case .takeEnded(let ended):
                // The microphone changed: the take is kept up to that point.
                settled = ended
                atLimit = false
            case .aborted:
                try checkpoint()
                continue recording
            case .event:
                continue recording
            }
            break recording
        }
        try checkpoint()

        state = .finishingTake
        await speech.play(.ended)
        try checkpoint()
        if atLimit {
            await speech.speak(DriveScript.timeLimit)
            try checkpoint()
        } else if case .kept = settled {
            await speech.speak(DriveScript.takeEnded)
            try checkpoint()
        }

        let spoken: [String]
        switch settled {
        case .kept(let take):
            spoken = try await feedback(for: take)
        case .empty:
            lastReport = nil
            spoken = Self.spoken(DriveScript.noAnswer)
        case .failed, .none:
            lastReport = nil
            spoken = Self.spoken(DriveScript.notSaved)
        }
        lastFeedback = spoken
        state = .speakingFeedback
        await speech.speak(segments: spoken)
        try checkpoint()
        return .commands(intro: nil)
    }

    /// Uploads a kept take, waits for its analysis, and returns what to say about it.
    private func feedback(for take: LocalTake) async throws -> [String] {
        state = .uploading
        // Takes still waiting from earlier go first, so the server gets attempts in order.
        await syncTask?.value
        try checkpoint()
        let api = self.api()
        let sync = self.sync
        let store = self.store
        let takeID = take.id
        let controller = ProcessingController(
            takeID: takeID, api: api, needsUpload: true,
            upload: { progress in try await sync.upload(takeID: takeID, progress: progress) },
            sleep: { [weak self] duration in
                guard let self else { throw CancellationError() }
                try await self.pollPause(duration)
            })
        controller.onUpdate = { store.update(remote: $0) }
        let started = clock.now
        waiting = Waiting(
            controller: controller, start: started, deadline: started + config.waitLimit,
            lines: config.stillWorkingAt.sorted())
        defer { waiting = nil }
        await controller.run()
        try checkpoint()

        lastReport = nil
        switch controller.phase {
        case .uploadFailed:
            // Offline or a server error: the take stays queued for `TakeSync.syncPending`.
            return Self.spoken(DriveScript.offline)
        case .done(let remote):
            var report: TakeReport?
            if remote.coachingStatus == .done {
                report = try? await api.report(takeID: takeID)
                try checkpoint()
            }
            lastReport = report
            return Self.spoken(DriveScript.feedback(for: remote, report: report))
        case .failed:
            guard let remote = store.take(id: takeID)?.remote else { return [DriveScript.waitTimedOut] }
            return Self.spoken(DriveScript.feedback(for: remote, report: nil))
        case .uploading, .processing:
            feedbackLater.append(takeID)
            return [DriveScript.waitTimedOut]
        }
    }

    private struct Waiting {
        let controller: ProcessingController
        let start: TimeInterval
        var deadline: TimeInterval
        /// "Still working." times not said yet.
        var lines: [TimeInterval]
        var extended = false
    }

    /// The pause between polls: says "Still working." when it is time, and gives up waiting
    /// (by throwing, which ends the controller's polling) at the limit.
    private func pollPause(_ duration: Duration) async throws {
        try await clock.sleep(for: duration.timeInterval)
        try checkpoint()
        guard let controller = waiting?.controller, let start = waiting?.start else { throw CancellationError() }
        if case .processing = controller.phase { state = .waiting }
        if let line = waiting?.lines.first, clock.now - start >= line {
            waiting?.lines.removeFirst()
            await speech.speak(DriveScript.stillWorking)
            try checkpoint()
        }
        guard let current = waiting, clock.now >= current.deadline else { return }
        if !current.extended, case .processing(let status) = controller.phase, status == .coaching {
            // The analysis is done and coaching is running: worth a little more time.
            waiting?.extended = true
            waiting?.deadline += config.coachingGrace
            return
        }
        throw CancellationError()
    }

    /// Between takes: waits for a command.
    private func commands(intro: String?) async throws -> Step {
        try checkpoint()
        if let intro {
            await speech.speak(intro)
            try checkpoint()
        }
        state = .awaitingCommand
        var deadline = clock.now + config.idleLimit
        var helped = false
        while true {
            let heard = await hear(.betweenTakes, from: speech.outputEnd, timeout: max(0, deadline - clock.now))
            var command: CommandSpotter.Command?
            switch heard {
            case .aborted:
                try checkpoint()
                continue
            case .timeout:
                return .end(.idle, line: DriveScript.idleEnd, askAfter: false)
            case .event(.command(let heardCommand)):
                command = heardCommand
            case .event, .takeEnded:
                command = nil
            }

            switch command {
            case .again?:
                return .prompt(retry: true)
            case .next?:
                return .prompt(retry: false)
            case .stop?:
                return .end(.stopped, line: nil, askAfter: true)
            case .repeatThat?:
                state = .speakingFeedback
                await speech.speak(segments: lastFeedback ?? [DriveScript.nothingToRepeat])
                try checkpoint()
                deadline = clock.now + config.idleLimit
            case .betterVersion?:
                state = .speakingReference
                let reading = DriveScript.referenceVersion(report: lastReport)
                await speech.speak(segments: reading.segments + [reading.options])
                try checkpoint()
                deadline = clock.now + config.idleLimit
            case .rating?, .skip?, nil:
                // Not a command here. The command list is said once per break.
                guard !helped else { continue }
                helped = true
                await speech.speak(DriveScript.commandHelp)
                try checkpoint()
            }
            state = .awaitingCommand
        }
    }

    /// The after-rating when asked for, the closing line, and everything stopped.
    private func end(_ reason: EndReason, line: String?, askAfter: Bool) async {
        state = .ending
        // What disrupted the drive is handled by ending it. Later disruptions only cut
        // the closing words short.
        disruptions.removeAll()
        if let line { await speech.speak(line) }
        var after: Int?
        if askAfter, sessionID != nil {
            state = .askingNervousness(.after)
            after = try? await askRating(DriveScript.nervousnessAfterQuestion)
            state = .ending
        }
        _ = await finishOpenTake(cutAt: nil, reason: .finished)
        if let sessionID { store.endSession(sessionID, endedAt: Date(), nervousnessAfter: after) }
        await speech.speak(DriveScript.driveEnded(takes: takesSaved))

        spotter.stopListening()
        await recognizer.stop()
        recognition?.cancel()
        recognition = nil
        _ = settle(await audio.stop())
        audio.onEvent = nil
        state = .ended(reason)
        syncInBackground()
    }

    // MARK: - Disruptions

    private enum Disruption: Equatable {
        /// A call or Siri. `cut` is true when it ended a take that was kept.
        case interrupted(cut: Bool)
        case audioFailed(String)
        case commandsFailed(String)
        case stopTapped
    }

    private struct Disrupted: Error {}

    /// Throws when something outside the sequence needs handling. Called after every await.
    private func checkpoint() throws {
        if !disruptions.isEmpty { throw Disrupted() }
    }

    private func disrupt(_ disruption: Disruption) {
        guard state.isActive else { return }
        if case .interrupted(let cut) = disruption,
            let index = disruptions.firstIndex(where: { if case .interrupted = $0 { true } else { false } })
        {
            // A second call before the loop handled the first: one pause, for the latest.
            if case .interrupted(let earlier) = disruptions[index] { disruptions[index] = .interrupted(cut: earlier || cut) }
        } else {
            disruptions.append(disruption)
        }
        resolveHearing(.aborted)
        switch disruption {
        case .interrupted:
            // The audio core already dropped what was playing. A pause goes on until the
            // audio comes back: a new interruption can only start after the last one ended.
            break
        case .audioFailed, .commandsFailed, .stopTapped:
            speech.cancel()
            if let waiter = pauseWaiter {
                pauseWaiter = nil
                waiter.resume(returning: nil)
            }
        }
    }

    /// Handles the oldest disruption and says where the drive goes next.
    private func handleDisruption() async -> Step {
        // A take kept outside the sequence uploads in the background.
        syncInBackground()
        guard !disruptions.isEmpty else {
            Self.log.fault("A step stopped with nothing to handle")
            return .end(.audioFailed("The drive stopped unexpectedly."), line: nil, askAfter: false)
        }
        switch disruptions.removeFirst() {
        case .stopTapped:
            _ = await finishOpenTake(cutAt: nil, reason: .finished)
            return .end(.stoppedFromApp, line: nil, askAfter: false)
        case .commandsFailed(let message):
            // Without commands no take can end and no command can be heard.
            _ = await finishOpenTake(cutAt: nil, reason: .finished)
            return .end(.commandsUnavailable(message), line: DriveScript.commandsUnavailable, askAfter: false)
        case .audioFailed(let message):
            return .end(.audioFailed(message), line: DriveScript.microphoneUnavailable, askAfter: false)
        case .interrupted(let cut):
            state = .paused
            switch await interruptionEnded() {
            case true?:
                guard sessionID != nil else { return .opening }
                return .commands(intro: cut ? DriveScript.cutOff : DriveScript.commandHelp)
            case false?:
                return .end(.interrupted, line: nil, askAfter: false)
            case nil:
                return await handleDisruption()
            }
        }
    }

    /// Whether the audio came back after an interruption; nil when another disruption came first.
    private func interruptionEnded() async -> Bool? {
        if let resumed = interruptionEnd {
            interruptionEnd = nil
            return resumed
        }
        guard disruptions.isEmpty else { return nil }
        return await withCheckedContinuation { pauseWaiter = $0 }
    }

    // MARK: - Hearing

    private enum Heard {
        case event(CommandSpotter.Event)
        /// The audio core ended the take (the microphone changed).
        case takeEnded(Settled)
        case timeout
        /// A disruption: the caller's `checkpoint()` throws.
        case aborted
    }

    /// Listens for what `mode` allows, from drive time `time`, for at most `timeout` seconds.
    private func hear(_ mode: CommandSpotter.Mode, from time: TimeInterval, timeout: TimeInterval) async -> Heard {
        guard disruptions.isEmpty else { return .aborted }
        if mode == .recording, let ended = endedTake {
            endedTake = nil
            return .takeEnded(ended)
        }
        spotter.listen(mode: mode, from: time)
        recognizer.listen(mode: mode, from: time)
        hearTicket += 1
        let ticket = hearTicket
        let clock = self.clock
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            self?.resolveHearing(.timeout, ticket: ticket)
        }
        let heard = await withCheckedContinuation { hearWaiter = (ticket, $0) }
        timer.cancel()
        spotter.stopListening()
        recognizer.stopListening()
        return heard
    }

    private func resolveHearing(_ heard: Heard, ticket: Int? = nil) {
        guard let waiter = hearWaiter, ticket == nil || ticket == waiter.ticket else { return }
        hearWaiter = nil
        waiter.continuation.resume(returning: heard)
    }

    private func listen(to events: AsyncStream<CommandRecognizerEvent>) {
        recognition = Task { [weak self] in
            for await event in events {
                self?.recognizerEvent(event)
            }
        }
    }

    private func recognizerEvent(_ event: CommandRecognizerEvent) {
        switch event {
        case .update(let update):
            let events = spotter.receive(update)
            // A command in the same result as an unrecognized utterance before it wins.
            if let event = events.first(where: { $0 != .unrecognizedSpeech }) ?? events.first {
                resolveHearing(.event(event))
            }
        case .failed(let message):
            Self.log.error("Commands failed: \(message, privacy: .public)")
            disrupt(.commandsFailed(message))
        }
    }

    // MARK: - Takes

    /// A take after its end: kept in the store, or why there is nothing to keep.
    private enum Settled: Equatable {
        case kept(LocalTake)
        case empty
        case failed(String)
        /// No take was open.
        case none

        var isKept: Bool {
            if case .kept = self { true } else { false }
        }
    }

    /// Puts a kept take in the store as the prompt's next attempt. Every `TakeEnd` comes
    /// through here exactly once.
    private func settle(_ end: DriveAudio.TakeEnd?) -> Settled {
        guard let end, let take = openTake else { return .none }
        openTake = nil
        switch end {
        case .kept(let finished):
            guard
                let kept = store.keepTake(
                    id: take.id, promptID: take.promptID, recording: finished.recording, sha256: finished.sha256)
            else {
                // Only when the prompt left the store (a reset): the file stays for the prune.
                Self.log.error("A take could not be kept: its prompt is gone")
                return .failed("The prompt is no longer on this phone.")
            }
            return .kept(kept)
        case .empty:
            return .empty
        case .failed(_, let message):
            Self.log.error("A take could not be written: \(message, privacy: .public)")
            return .failed(message)
        }
    }

    /// Closes the open take and keeps it. When the audio core ended it first, waits for the
    /// event that carries it.
    private func finishOpenTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async -> Settled {
        if let ended = endedTake {
            endedTake = nil
            return ended
        }
        guard openTake != nil else { return .none }
        if let end = await audio.finishTake(cutAt: cutAt, reason: reason) { return settle(end) }
        if let ended = endedTake {
            endedTake = nil
            return ended
        }
        // An interruption or failure event already settled it.
        guard openTake != nil else { return .none }
        return await withCheckedContinuation { finishWaiter = $0 }
    }

    private func audioEvent(_ event: DriveAudio.Event) {
        switch event {
        case .takeEnded(let end):
            deliver(settle(end), toHearing: true)
        case .interrupted(let end):
            let settled = settle(end)
            deliver(settled, toHearing: false)
            interruptionEnd = nil
            disrupt(.interrupted(cut: settled.isKept))
        case .interruptionEnded(let resumed):
            if let waiter = pauseWaiter {
                pauseWaiter = nil
                waiter.resume(returning: resumed)
            } else {
                interruptionEnd = resumed
            }
        case .failed(let message, let end):
            Self.log.error("The drive's audio failed: \(message, privacy: .public)")
            deliver(settle(end), toHearing: false)
            disrupt(.audioFailed(message))
        }
    }

    /// Hands a take the audio core ended to whoever waits for it.
    private func deliver(_ settled: Settled, toHearing: Bool) {
        guard settled != .none else { return }
        if let waiter = finishWaiter {
            finishWaiter = nil
            waiter.resume(returning: settled)
        } else if toHearing, hearWaiter != nil {
            resolveHearing(.takeEnded(settled))
        } else if toHearing {
            endedTake = settled
        }
    }

    // MARK: - Background work

    /// Uploads waiting takes and sends session ends, when the server answers.
    private func syncInBackground() {
        let previous = syncTask
        syncTask = Task { [weak self] in
            await previous?.value
            guard let self, (try? await self.api().health()) != nil else { return }
            await self.sync.syncPending()
        }
    }

    private func prefetchQuestions() {
        guard questionsTask == nil else { return }
        questionsTask = Task { [weak self] in
            await self?.questions.prefetch()
            self?.questionsTask = nil
        }
    }

    private static func spoken(_ feedback: DriveScript.Feedback) -> [String] {
        feedback.segments + [feedback.options]
    }
}

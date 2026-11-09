import Foundation
@testable import SpeakUp

/// Time that moves only when a test moves it, so a six-minute take or a ten-minute idle wait
/// runs at once.
final class ManualDriveClock: DriveLoopClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let wake: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [Sleeper] = []

    var now: TimeInterval { lock.withLock { current } }

    var hasSleepers: Bool { lock.withLock { !sleepers.isEmpty } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers.append(Sleeper(id: id, wake: current + max(0, seconds), continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock {
                let found = sleepers.first { $0.id == id }
                sleepers.removeAll { $0.id == id }
                return found
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves to the earliest wake time and wakes everyone due then. False when nobody sleeps.
    @discardableResult
    func advanceToNextWake() -> Bool {
        let due: [Sleeper]? = lock.withLock {
            guard let wake = sleepers.map(\.wake).min() else { return nil }
            current = max(current, wake)
            let due = sleepers.filter { $0.wake <= current }
            sleepers.removeAll { $0.wake <= current }
            return due
        }
        guard let due else { return false }
        for sleeper in due { sleeper.continuation.resume() }
        return true
    }
}

/// Records what the drive says; every item takes one second of output.
@MainActor
final class FakeSpeech: SpeechOutputting {
    private(set) var outputEnd: TimeInterval = 0
    /// Every utterance and tone, in order: `say: ...` and `tone: ...`.
    private(set) var log: [String] = []
    private(set) var cancels = 0

    /// Only what was said, one entry per segment.
    var said: [String] {
        log.compactMap { $0.hasPrefix("say: ") ? String($0.dropFirst(5)) : nil }
    }

    func speak(_ text: String) async -> SpeechPlayback {
        await speak(segments: [text])
    }

    func speak(segments: [String]) async -> SpeechPlayback {
        for segment in segments {
            log.append("say: \(segment)")
            outputEnd += 1
        }
        await Task.yield()
        return SpeechPlayback(finished: true, end: outputEnd, duration: Double(segments.count))
    }

    func play(_ tone: DriveTone) async -> SpeechPlayback {
        log.append("tone: \(tone.logName)")
        outputEnd += 1
        await Task.yield()
        return SpeechPlayback(finished: true, end: outputEnd, duration: 1)
    }

    func cancel() {
        cancels += 1
    }
}

/// Hears what a test scripts: each `listen` takes the next line of its mode and reports its
/// words as final, one second into the window, followed by enough silence to act on them.
@MainActor
final class FakeRecognizer: CommandRecognizing {
    var prepareError: (any Error)?
    /// Per mode, one entry per listening window; nil hears nothing.
    var lines: [CommandSpotter.Mode: [String?]] = [:]
    private(set) var listens: [(mode: CommandSpotter.Mode, time: TimeInterval)] = []
    private(set) var stopped = false
    private var continuation: AsyncStream<CommandRecognizerEvent>.Continuation?

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func start(buffers: AsyncStream<DriveAudioBuffer>) async throws -> AsyncStream<CommandRecognizerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CommandRecognizerEvent.self)
        self.continuation = continuation
        return stream
    }

    func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        listens.append((mode, time))
        guard var queue = lines[mode], !queue.isEmpty else { return }
        let line = queue.removeFirst()
        lines[mode] = queue
        guard let line else { return }
        var words: [CommandSpotter.TimedWord] = []
        var start = time + 1
        for text in line.split(separator: " ") {
            words.append(.init(String(text), start: start, end: start + 0.3))
            start += 0.35
        }
        continuation?.yield(.update(.init(words: words, isFinal: true, progress: start + 3)))
    }

    func stopListening() {}

    /// Says `line` now, in the window the last `listen` opened.
    func say(_ line: String) {
        guard let last = listens.last else { return }
        lines[last.mode] = [line] + (lines[last.mode] ?? [])
        listens.removeLast()
        listen(mode: last.mode, from: last.time)
    }

    func stop() async {
        stopped = true
        continuation?.finish()
    }

    /// The recognizer stops working mid-drive.
    func fail(_ message: String) {
        continuation?.yield(.failed(message))
    }
}

/// The drive audio core without audio: a take is a file written when it finishes.
@MainActor
final class FakeDriveAudio: DriveAudioControlling {
    var now: TimeInterval = 0
    var takeDuration: TimeInterval? { openURL == nil ? nil : 30 }
    var onEvent: ((DriveAudio.Event) -> Void)?
    var startError: (any Error)?
    /// How the next take that `finishTake` closes ends; kept by default.
    var nextEnd: ((URL, AudioRecorder.StopReason) -> DriveAudio.TakeEnd)?
    private(set) var opened: [(url: URL, start: TimeInterval?)] = []
    private(set) var finished: [(cutAt: TimeInterval?, reason: AudioRecorder.StopReason)] = []
    private(set) var openURL: URL?
    private(set) var isRunning = false

    var isTakeOpen: Bool { openURL != nil }

    func start() async throws {
        if let startError { throw startError }
        isRunning = true
    }

    func stop() async -> DriveAudio.TakeEnd? {
        isRunning = false
        guard let url = openURL else { return nil }
        openURL = nil
        return Self.kept(url, reason: .finished)
    }

    func recognizerBuffers() -> AsyncStream<DriveAudioBuffer> {
        AsyncStream { $0.finish() }
    }

    func openTake(url: URL, at start: TimeInterval?) throws {
        guard isRunning else { throw DriveAudio.DriveAudioError.notRunning }
        guard openURL == nil else { throw DriveAudio.DriveAudioError.takeAlreadyOpen }
        openURL = url
        opened.append((url, start))
    }

    func finishTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async -> DriveAudio.TakeEnd? {
        guard let url = openURL else { return nil }
        openURL = nil
        finished.append((cutAt, reason))
        let end = nextEnd?(url, reason) ?? Self.kept(url, reason: reason)
        nextEnd = nil
        return end
    }

    /// The audio core ends the open take by itself and reports it in `event`.
    func endTake(_ event: (DriveAudio.TakeEnd?) -> DriveAudio.Event) {
        let end = openURL.map { Self.kept($0, reason: .interrupted) }
        openURL = nil
        onEvent?(event(end))
    }

    func send(_ event: DriveAudio.Event) {
        onEvent?(event)
    }

    /// A kept take: a small file at `url`, as the store expects.
    static func kept(_ url: URL, reason: AudioRecorder.StopReason) -> DriveAudio.TakeEnd {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("RIFF".utf8).write(to: url)
        let recording = AudioRecorder.Recording(
            url: url, recordedAt: Date(), duration: 30, sampleRate: 16_000, micRoute: .builtIn,
            micName: "iPhone Microphone", stopReason: reason)
        return .kept(.init(recording: recording, sha256: "abc123", gaps: []))
    }
}

/// A server for drive tests on top of `FakeAPI`: it can go offline, and each take moves
/// through the statuses its `Processing` gives.
final class DriveServer: @unchecked Sendable {
    enum Processing: Sendable {
        /// Transcribing on the first poll, then done with coaching.
        case coached
        /// Done without coaching: metrics only.
        case noCoaching
        /// Never finishes analyzing.
        case stuck
        /// Analysis done, coaching running, then done with coaching after `polls` more polls.
        case slowCoaching(polls: Int)
        /// Failed: fewer than five words.
        case noSpeech
    }

    let api = FakeAPI()
    private let lock = NSLock()
    private var _online = true
    private var _processing: Processing = .coached
    private var uploads: [String: TakeUploadMetadata] = [:]
    private var uploadOrder: [String] = []
    private var polls: [String: Int] = [:]
    private var _createdSessions: [String: SessionCreateRequest] = [:]
    private var _endedSessions: [String: SessionEndRequest] = [:]
    private var _createdPrompts: [String: PromptCreateRequest] = [:]

    /// What the server was sent. The phone drops a session once the server has all of it,
    /// so these are what a test checks after a drive.
    var createdSessions: [String: SessionCreateRequest] { lock.withLock { _createdSessions } }
    var endedSessions: [String: SessionEndRequest] { lock.withLock { _endedSessions } }
    var createdPrompts: [String: PromptCreateRequest] { lock.withLock { _createdPrompts } }

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }

    var processing: Processing {
        get { lock.withLock { _processing } }
        set { lock.withLock { _processing = newValue } }
    }

    /// Uploaded takes in upload order, with their metadata.
    var uploaded: [(id: String, metadata: TakeUploadMetadata)] {
        lock.withLock { uploadOrder.map { ($0, uploads[$0]!) } }
    }

    init() {
        let offline = APIError.transport(code: .notConnectedToInternet, message: "The Internet connection appears to be offline.")
        api.onHealth = { [unowned self] in
            guard online else { throw offline }
            return try Fixture.decode(Health.self, "health")
        }
        api.onQuestions = { [unowned self] request in
            guard online else { throw offline }
            let questions = (0..<request.count).map {
                Question(text: "Server question \($0 + 1)?", category: .decision, targetSeconds: 90)
            }
            return QuestionsResponse(source: .claude, questions: questions)
        }
        api.onCreateSession = { [unowned self] id, body in
            guard online else { throw offline }
            lock.withLock { _createdSessions[id] = body }
            return Session(
                id: id, mode: body.mode, startedAt: body.startedAt, endedAt: nil,
                nervousnessBefore: body.nervousnessBefore, nervousnessAfter: nil, createdAt: Date(), updatedAt: Date())
        }
        api.onEndSession = { [unowned self] id, body in
            guard online else { throw offline }
            lock.withLock { _endedSessions[id] = body }
            return Session(
                id: id, mode: .driving, startedAt: Date(), endedAt: body.endedAt, nervousnessBefore: nil,
                nervousnessAfter: body.nervousnessAfter, createdAt: Date(), updatedAt: Date())
        }
        api.onCreatePrompt = { [unowned self] id, body in
            guard online else { throw offline }
            lock.withLock { _createdPrompts[id] = body }
            return Prompt(
                id: id, sessionId: body.sessionId, kind: body.kind, text: body.text, notes: body.notes,
                category: body.category, targetSeconds: body.targetSeconds,
                questionSource: body.questionSource, createdAt: Date())
        }
        api.onUpload = { [unowned self] id, metadata in
            guard online else { throw offline }
            lock.withLock {
                if uploads[id] == nil { uploadOrder.append(id) }
                uploads[id] = metadata
            }
            return take(id: id, status: .uploaded, coaching: .pending)
        }
        api.onTake = { [unowned self] id in
            guard online else { throw offline }
            let (count, processing) = lock.withLock {
                polls[id, default: 0] += 1
                return (polls[id]!, _processing)
            }
            switch processing {
            case .coached:
                return count < 2 ? take(id: id, status: .transcribing, coaching: .pending) : take(id: id, status: .done, coaching: .done)
            case .noCoaching:
                return count < 2 ? take(id: id, status: .analyzing, coaching: .pending) : take(id: id, status: .done, coaching: .unavailable)
            case .stuck:
                return take(id: id, status: .analyzing, coaching: .pending)
            case .slowCoaching(let more):
                return count <= more ? take(id: id, status: .coaching, coaching: .pending) : take(id: id, status: .done, coaching: .done)
            case .noSpeech:
                return take(id: id, status: .failed, coaching: .pending, error: ("no_speech", "Fewer than 5 words."))
            }
        }
        api.onReport = { [unowned self] id in
            guard online else { throw offline }
            var report = Fixture.fullReportObject()
            if (lock.withLock { uploads[id]?.attempt ?? 1 }) > 1, var coaching = report["coaching"] as? [String: Any] {
                coaching["comparison"] = Fixture.object("coaching_comparison")
                report["coaching"] = coaching
            }
            return try Fixture.decode(TakeReport.self, object: report)
        }
    }

    /// A Take resource for an uploaded take, linked to the attempt before it like the server's.
    func take(
        id: String, status: TakeStatus, coaching: CoachingStatus, error: (String, String)? = nil
    ) -> Take {
        let (metadata, previous) = lock.withLock { () -> (TakeUploadMetadata?, String?) in
            let metadata = uploads[id]
            let previous = uploadOrder.first {
                uploads[$0]?.promptId == metadata?.promptId && uploads[$0]?.attempt == (metadata?.attempt ?? 1) - 1
            }
            return (metadata, previous)
        }
        var object = Fixture.object("take_done")
        object["id"] = id
        if let metadata {
            object["prompt_id"] = metadata.promptId
            object["attempt"] = metadata.attempt
        }
        object["previous_take_id"] = previous ?? NSNull()
        object["status"] = status.rawValue
        object["coaching_status"] = coaching.rawValue
        object["error"] = error.map { ["code": $0.0, "message": $0.1] } ?? NSNull()
        if status != .done {
            object["summary"] = NSNull()
        } else if coaching != .done {
            object["summary"] = [
                "verdict": NSNull(), "focus_titles": [String](), "fillers_per_100_words": 4.2, "blocks": 2,
                "restarts": 0, "wpm_voiced": 151.0,
            ] as [String: Any]
        }
        return try! Fixture.decode(Take.self, object: object)
    }
}

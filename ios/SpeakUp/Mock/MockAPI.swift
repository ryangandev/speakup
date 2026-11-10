#if DEBUG
import Foundation

/// What the debug mock server does, picked in Settings or with `-debug.mockScenario`.
enum MockScenario: String, CaseIterable, Sendable {
    case normal
    case coachingUnavailable
    case coachingFailed
    case noSpeech
    case processingFails
    case uploadFails
    case slowProcessing
    case unreachable

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .coachingUnavailable: return "No API key (coaching off)"
        case .coachingFailed: return "Coaching fails"
        case .noSpeech: return "No speech detected"
        case .processingFails: return "Speech to text fails"
        case .uploadFails: return "Upload fails"
        case .slowProcessing: return "Slow processing"
        case .unreachable: return "Server unreachable"
        }
    }
}

/// An in-memory server for debug builds: same shapes and status codes as the contract,
/// with takes moving through their statuses over a few seconds, and seeded history.
final class MockAPI: SpeakUpAPI, @unchecked Sendable {
    static let shared = MockAPI()

    private struct TakeRecord {
        let id: String
        let promptId: String
        let sessionId: String
        let attempt: Int
        let recordedAt: Date
        let durationS: Double
        let micRoute: MicRoute
        let createdAt: Date
        var processStart: Date
        /// Index into `stageDurations` where processing (re)started.
        var startStage: Int
        var scenario: MockScenario
    }

    private let lock = NSLock()
    private var storedScenario = MockScenario.normal
    private var sessions: [String: Session] = [:]
    private var prompts: [String: Prompt] = [:]
    private var takes: [String: TakeRecord] = [:]
    private var questionCursor = 0
    private let audioDirectory = FileManager.default.temporaryDirectory.appending(path: "MockAudio")

    var scenario: MockScenario {
        get { lock.withLock { storedScenario } }
        set { lock.withLock { storedScenario = newValue } }
    }

    init(seed: Bool = true, now: Date = Date()) {
        if seed { seedHistory(now: now) }
    }

    // MARK: Endpoints

    func health() async throws -> Health {
        try await pause(0.3)
        let scenario = try reachableScenario()
        let available = scenario != .coachingUnavailable
        return Health(
            status: "ok", apiVersion: "v1", serverVersion: "0.2.0-mock", sttEngine: "crisperwhisper",
            coaching: CoachingInfo(
                available: available, model: available ? "claude-opus-5-5" : nil,
                rubricVersion: "rubric/1", promptVersion: "coach-prompt/1"),
            queueLength: 0)
    }

    func createSession(id: String, _ body: SessionCreateRequest) async throws -> Session {
        try await pause(0.2)
        _ = try reachableScenario()
        return lock.withLock {
            if let existing = sessions[id] { return existing }
            let now = Date()
            let session = Session(
                id: id, mode: body.mode, startedAt: body.startedAt, endedAt: nil,
                nervousnessBefore: body.nervousnessBefore, nervousnessAfter: nil, createdAt: now, updatedAt: now)
            sessions[id] = session
            return session
        }
    }

    func endSession(id: String, _ body: SessionEndRequest) async throws -> Session {
        try await pause(0.2)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let old = sessions[id] else { throw Self.notFound("session", id) }
            let session = Session(
                id: id, mode: old.mode, startedAt: old.startedAt, endedAt: old.endedAt ?? body.endedAt,
                nervousnessBefore: old.nervousnessBefore, nervousnessAfter: body.nervousnessAfter,
                createdAt: old.createdAt, updatedAt: Date())
            sessions[id] = session
            return session
        }
    }

    func sessions(before: Date?, limit: Int) async throws -> SessionList {
        try await pause(0.4)
        _ = try reachableScenario()
        return lock.withLock {
            let cutoff = before ?? .distantFuture
            let sorted = sessions.values.filter { $0.startedAt < cutoff }.sorted { $0.startedAt > $1.startedAt }
            let page = Array(sorted.prefix(limit))
            let items = page.map { session -> SessionListItem in
                let sessionPrompts = prompts.values.filter { $0.sessionId == session.id }.sorted { $0.createdAt < $1.createdAt }
                let summaries = sessionPrompts.map { prompt in
                    PromptSummary(
                        id: prompt.id, kind: prompt.kind, text: prompt.text,
                        takeCount: takes.values.filter { $0.promptId == prompt.id }.count)
                }
                return Self.listItem(session: session, prompts: summaries, takeCount: summaries.map(\.takeCount).reduce(0, +))
            }
            return SessionList(sessions: items, nextBefore: sorted.count > limit ? page.last?.startedAt : nil)
        }
    }

    func session(id: String) async throws -> SessionDetail {
        try await pause(0.3)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let session = sessions[id] else { throw Self.notFound("session", id) }
            let now = Date()
            let details = prompts.values.filter { $0.sessionId == id }.sorted { $0.createdAt < $1.createdAt }.map {
                prompt in
                Self.promptDetail(prompt, takes: takeResources(promptID: prompt.id, now: now))
            }
            return Self.sessionDetail(session, prompts: details)
        }
    }

    func questions(_ body: QuestionsRequest) async throws -> QuestionsResponse {
        try await pause(0.6)
        let scenario = try reachableScenario()
        return lock.withLock {
            let pool = MockContent.questions.filter {
                (body.category == nil || $0.category == body.category) && !body.exclude.contains($0.text)
            }
            let source = pool.isEmpty ? MockContent.questions.filter { body.category == nil || $0.category == body.category } : pool
            var picked: [Question] = []
            for offset in 0..<min(body.count, source.count) {
                picked.append(source[(questionCursor + offset) % source.count])
            }
            questionCursor += body.count
            return QuestionsResponse(source: scenario == .coachingUnavailable ? .bank : .claude, questions: picked)
        }
    }

    func createPrompt(id: String, _ body: PromptCreateRequest) async throws -> Prompt {
        try await pause(0.2)
        _ = try reachableScenario()
        return try lock.withLock {
            if let existing = prompts[id] { return existing }
            guard sessions[body.sessionId] != nil else { throw Self.notFound("session", body.sessionId) }
            let prompt = Prompt(
                id: id, sessionId: body.sessionId, kind: body.kind, text: body.text, notes: body.notes,
                category: body.category, targetSeconds: body.targetSeconds, questionSource: body.questionSource,
                language: body.language, createdAt: Date())
            prompts[id] = prompt
            return prompt
        }
    }

    func prompt(id: String) async throws -> PromptDetail {
        try await pause(0.2)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let prompt = prompts[id] else { throw Self.notFound("prompt", id) }
            return Self.decode(merging: Self.promptDetail(prompt, takes: takeResources(promptID: id, now: Date())), extra: [:])
        }
    }

    func uploadTake(
        id: String, metadata: TakeUploadMetadata, audioFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take {
        let scenario = try reachableScenario()
        for step in 1...8 {
            try await pause(0.1)
            progress(Double(step) / 8)
            if scenario == .uploadFails, step == 4 {
                throw APIError.transport(code: .networkConnectionLost, message: "The network connection was lost.")
            }
        }
        return try lock.withLock {
            if let existing = takes[id] { return resource(existing, now: Date()) }
            guard let prompt = prompts[metadata.promptId] else { throw Self.notFound("prompt", metadata.promptId) }
            let now = Date()
            let record = TakeRecord(
                id: id, promptId: prompt.id, sessionId: prompt.sessionId, attempt: metadata.attempt,
                recordedAt: metadata.recordedAt, durationS: metadata.durationS, micRoute: metadata.micRoute,
                createdAt: now, processStart: now, startStage: 0, scenario: scenario)
            takes[id] = record
            return resource(record, now: now)
        }
    }

    func take(id: String) async throws -> Take {
        try await pause(0.1)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let record = takes[id] else { throw Self.notFound("take", id) }
            return resource(record, now: Date())
        }
    }

    func report(takeID: String) async throws -> TakeReport {
        try await pause(0.4)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let record = takes[takeID], let prompt = prompts[record.promptId] else {
                throw Self.notFound("take", takeID)
            }
            let take = resource(record, now: Date())
            guard take.status == .coaching || take.status == .done else {
                throw APIError.server(
                    status: 409, code: "not_ready", message: "The take has no analysis yet.",
                    details: .object(["status": .string(take.status.rawValue)]))
            }
            let (analysis, coaching) = documents(for: record, take: take)
            return TakeReport(
                take: take, prompt: prompt, analysis: analysis, coaching: coaching,
                hasComparison: previousRecord(of: record) != nil)
        }
    }

    func comparison(takeID: String) async throws -> Comparison {
        try await pause(0.3)
        _ = try reachableScenario()
        return try lock.withLock {
            guard let record = takes[takeID] else { throw Self.notFound("take", takeID) }
            let now = Date()
            let take = resource(record, now: now)
            guard take.status == .done else {
                throw APIError.server(
                    status: 409, code: "not_ready", message: "The take is not done yet.",
                    details: .object(["status": .string(take.status.rawValue)]))
            }
            guard let previousRecord = previousRecord(of: record) else {
                throw APIError.server(
                    status: 404, code: "no_previous_take", message: "This take has no previous take.", details: nil)
            }
            let previous = resource(previousRecord, now: now)
            let (analysis, coaching) = documents(for: record, take: take)
            let (previousAnalysis, previousCoaching) = documents(for: previousRecord, take: previous)
            return MockContent.comparison(
                take: take, previous: previous, analysis: analysis, previousAnalysis: previousAnalysis,
                coaching: coaching, previousCoaching: previousCoaching)
        }
    }

    func audio(takeID: String) async throws -> URL {
        try await pause(0.3)
        _ = try reachableScenario()
        let duration = try lock.withLock {
            guard let record = takes[takeID] else { throw Self.notFound("take", takeID) }
            return record.durationS
        }
        let url = audioDirectory.appending(path: "\(takeID).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // A quiet tone the length of the take, so playback can be heard without a real recording.
        let rate = 16_000
        let writer = try WAVWriter(url: url, sampleRate: rate)
        let samples = (0..<Int(duration * Double(rate))).map { index in
            Int16(sin(Double(index) * 2 * .pi * 220 / Double(rate)) * 2_000)
        }
        try writer.append(samples)
        try writer.finish()
        return url
    }

    func reprocess(takeID: String, from stage: ReprocessStage) async throws -> Take {
        try await pause(0.2)
        let scenario = try reachableScenario()
        return try lock.withLock {
            guard var record = takes[takeID] else { throw Self.notFound("take", takeID) }
            let now = Date()
            let current = resource(record, now: now)
            guard current.status.isFinal else {
                throw APIError.server(
                    status: 409, code: "invalid_state", message: "The take is still processing.", details: nil)
            }
            record.processStart = now
            record.startStage = Self.stageIndex(of: stage)
            record.scenario = scenario
            takes[takeID] = record
            return resource(record, now: now)
        }
    }

    // MARK: Simulation

    private static let stages: [TakeStatus] = [.uploaded, .transcribing, .analyzing, .coaching]

    private static func stageIndex(of stage: ReprocessStage) -> Int {
        switch stage {
        case .transcribing: return 1
        case .analyzing: return 2
        default: return 3
        }
    }

    private func stageDurations(_ scenario: MockScenario) -> [Double] {
        // Coaching takes longest, as Claude does, so the report is seen while it runs.
        scenario == .slowProcessing ? [0.8, 600, 1.5, 5] : [0.8, 2, 1.5, 5]
    }

    /// The Take resource at `now`, from where processing started and how long each stage takes.
    private func resource(_ record: TakeRecord, now: Date) -> Take {
        var elapsed = now.timeIntervalSince(record.processStart)
        let durations = stageDurations(record.scenario)
        var status = TakeStatus.done
        var stageIndex = record.startStage
        while stageIndex < Self.stages.count {
            if elapsed < durations[stageIndex] {
                status = Self.stages[stageIndex]
                break
            }
            elapsed -= durations[stageIndex]
            stageIndex += 1
        }

        var error: TakeError?
        if record.scenario == .processingFails, stageIndex >= 2 {
            status = .failed
            error = TakeError(code: .sttFailed, message: "The speech-to-text engine failed after retries.")
        } else if record.scenario == .noSpeech, stageIndex >= 3 {
            status = .failed
            error = TakeError(code: .noSpeech, message: "Fewer than 5 words were transcribed.")
        }

        let coachingStatus: CoachingStatus
        switch status {
        case .done:
            switch record.scenario {
            case .coachingUnavailable: coachingStatus = .unavailable
            case .coachingFailed: coachingStatus = .failed
            default: coachingStatus = .done
            }
        default:
            coachingStatus = .pending
        }

        var summary: TakeSummary?
        if status == .done {
            let analysis = MockContent.analysis(
                takeID: record.id, attempt: record.attempt, durationS: record.durationS,
                coached: coachingStatus == .done, date: record.createdAt)
            let script = record.attempt % 2 == 1
            summary = TakeSummary(
                verdict: coachingStatus == .done
                    ? (script
                        ? "You named the decision first, but the reasons ran together and the end trailed off."
                        : "Much clearer: the decision comes first and the reasons are numbered. The ending still fades out.")
                    : nil,
                focusTitles: coachingStatus == .done
                    ? (script ? ["Number your reasons", "Stop silently, not mid-phrase"] : ["Close on purpose"]) : [],
                fillersPer100Words: analysis.metrics.fillers.per100Words, blocks: analysis.metrics.blocks.count,
                restarts: analysis.metrics.restarts, wpmVoiced: analysis.metrics.pace.wpmVoiced)
        }

        let changedAt = record.processStart
        return Take(
            id: record.id, promptId: record.promptId, sessionId: record.sessionId, attempt: record.attempt,
            recordedAt: record.recordedAt, durationS: record.durationS, micRoute: record.micRoute,
            status: status, statusChangedAt: changedAt, coachingStatus: coachingStatus,
            previousTakeId: previousRecord(of: record)?.id, error: error, summary: summary,
            createdAt: record.createdAt, updatedAt: changedAt)
    }

    private func previousRecord(of record: TakeRecord) -> TakeRecord? {
        let now = Date()
        return takes.values
            .filter { $0.promptId == record.promptId && $0.attempt < record.attempt }
            .filter { resourceStatusIsDone($0, now: now) }
            .max { $0.attempt < $1.attempt }
    }

    private func resourceStatusIsDone(_ record: TakeRecord, now: Date) -> Bool {
        let total = stageDurations(record.scenario)[record.startStage...].reduce(0, +)
        let failed = record.scenario == .processingFails || record.scenario == .noSpeech
        return !failed && now.timeIntervalSince(record.processStart) >= total
    }

    private func documents(for record: TakeRecord, take: Take) -> (Analysis, CoachingReport?) {
        let coached = take.coachingStatus == .done
        let analysis = MockContent.analysis(
            takeID: record.id, attempt: record.attempt, durationS: record.durationS, coached: coached,
            date: record.createdAt)
        guard coached else { return (analysis, nil) }
        var previousCoaching: CoachingReport?
        if let previous = previousRecord(of: record), previous.scenario != .coachingUnavailable,
            previous.scenario != .coachingFailed
        {
            let previousAnalysis = MockContent.analysis(
                takeID: previous.id, attempt: previous.attempt, durationS: previous.durationS, coached: true,
                date: previous.createdAt)
            previousCoaching = MockContent.coaching(
                takeID: previous.id, attempt: previous.attempt, analysis: previousAnalysis, previous: nil,
                date: previous.createdAt)
        }
        let coaching = MockContent.coaching(
            takeID: record.id, attempt: record.attempt, analysis: analysis, previous: previousCoaching,
            date: record.createdAt)
        return (analysis, coaching)
    }

    private func takeResources(promptID: String, now: Date) -> [Take] {
        takes.values.filter { $0.promptId == promptID }.sorted { $0.attempt < $1.attempt }.map { resource($0, now: now) }
    }

    private func reachableScenario() throws -> MockScenario {
        let scenario = scenario
        if scenario == .unreachable {
            throw APIError.transport(code: .cannotConnectToHost, message: "Could not connect to the server.")
        }
        return scenario
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func notFound(_ kind: String, _ id: String) -> APIError {
        .server(status: 404, code: "not_found", message: "No \(kind) with id \(id).", details: nil)
    }

    // MARK: Seed

    private func seedHistory(now: Date) {
        let day: TimeInterval = 24 * 60 * 60
        seedSession(
            start: now.addingTimeInterval(-1 * day), before: 3, after: 2,
            prompts: [
                ("Why did we choose Postgres over DynamoDB for the billing service?", .impromptu, .decision, 90, 2),
                ("Today's stand-up", .prepared, nil, 120, 1),
            ])
        seedSession(
            start: now.addingTimeInterval(-3 * day), before: 4, after: nil,
            prompts: [("Explain what a feature flag is to a new teammate who has never used one.", .impromptu, .explain, 90, 1)])
    }

    private func seedSession(
        start: Date, before: Int?, after: Int?,
        prompts seeds: [(String, PromptKind, PromptCategory?, Int, Int)]
    ) {
        let sessionID = IDs.make()
        var cursor = start
        for (text, kind, category, target, takeCount) in seeds {
            let promptID = IDs.make()
            prompts[promptID] = Prompt(
                id: promptID, sessionId: sessionID, kind: kind, text: text,
                notes: kind == .prepared ? "Shipped the invoice export. Blocked on the tax API keys. Next: retry logic." : nil,
                category: category, targetSeconds: target, questionSource: kind == .prepared ? .typed : .claude,
                language: .english, createdAt: cursor)
            for attempt in 1...takeCount {
                cursor = cursor.addingTimeInterval(150)
                let id = IDs.make()
                takes[id] = TakeRecord(
                    id: id, promptId: promptID, sessionId: sessionID, attempt: attempt, recordedAt: cursor,
                    durationS: attempt == 1 ? 96.4 : 78.2, micRoute: .builtIn, createdAt: cursor,
                    processStart: cursor, startStage: 0, scenario: .normal)
            }
        }
        sessions[sessionID] = Session(
            id: sessionID, mode: .home, startedAt: start, endedAt: cursor.addingTimeInterval(120),
            nervousnessBefore: before, nervousnessAfter: after, createdAt: start, updatedAt: cursor)
    }

    // The resources that wrap a Session are decoded from JSON in production; the mock builds
    // them the same way so it cannot drift from the decoders.
    private static func listItem(session: Session, prompts: [PromptSummary], takeCount: Int) -> SessionListItem {
        decode(merging: session, extra: ["prompts": prompts, "take_count": takeCount])
    }

    private struct PromptDetailPayload: Encodable {
        let prompt: Prompt
        let takes: [Take]

        func encode(to encoder: Encoder) throws {
            try prompt.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(takes, forKey: .takes)
        }

        private enum CodingKeys: String, CodingKey { case takes }
    }

    private static func promptDetail(_ prompt: Prompt, takes: [Take]) -> PromptDetailPayload {
        PromptDetailPayload(prompt: prompt, takes: takes)
    }

    private static func sessionDetail(_ session: Session, prompts: [PromptDetailPayload]) -> SessionDetail {
        decode(merging: session, extra: ["prompts": prompts])
    }

    private static func decode<Result: Decodable>(merging base: some Encodable, extra: [String: any Encodable]) -> Result {
        let encoder = JSONCoding.encoder()
        do {
            var object = try JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any] ?? [:]
            for (key, value) in extra {
                object[key] = try JSONSerialization.jsonObject(with: encoder.encode(AnyEncodable(value)), options: .fragmentsAllowed)
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONCoding.decoder().decode(Result.self, from: data)
        } catch {
            fatalError("Mock resource does not round-trip: \(error)")
        }
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        init(_ value: any Encodable) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
}
#endif

import Foundation
@testable import SpeakUp

/// A scriptable API: each test sets the handlers it needs; anything else fails loudly.
final class FakeAPI: SpeakUpAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _takeResponses: [Result<Take, APIError>] = []

    var onCreateSession: (@Sendable (String, SessionCreateRequest) throws -> Session)?
    var onEndSession: (@Sendable (String, SessionEndRequest) throws -> Session)?
    var onCreatePrompt: (@Sendable (String, PromptCreateRequest) throws -> Prompt)?
    var onUpload: (@Sendable (String, TakeUploadMetadata) throws -> Take)?
    var onReprocess: (@Sendable (String, ReprocessStage) throws -> Take)?
    /// Optional: without them, health and questions answer with the contract's examples,
    /// `take(id:)` with `queueTakeResponses`, and the report with the full example.
    var onHealth: (@Sendable () throws -> Health)?
    var onQuestions: (@Sendable (QuestionsRequest) throws -> QuestionsResponse)?
    var onTake: (@Sendable (String) throws -> Take)?
    var onReport: (@Sendable (String) throws -> TakeReport)?
    /// Optional: awaited before `onUpload`, so a test can hold an upload in flight.
    var beforeUpload: (@Sendable (String) async -> Void)?

    var calls: [String] { lock.withLock { _calls } }

    /// Responses for successive `take(id:)` polls; the last one repeats.
    func queueTakeResponses(_ responses: [Result<Take, APIError>]) {
        lock.withLock { _takeResponses = responses }
    }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func health() async throws -> Health {
        record("health")
        if let onHealth { return try onHealth() }
        return try Fixture.decode(Health.self, "health")
    }

    func createSession(id: String, _ body: SessionCreateRequest) async throws -> Session {
        record("createSession \(id)")
        guard let onCreateSession else { throw APIError.notConfigured }
        return try onCreateSession(id, body)
    }

    func endSession(id: String, _ body: SessionEndRequest) async throws -> Session {
        record("endSession \(id)")
        guard let onEndSession else { throw APIError.notConfigured }
        return try onEndSession(id, body)
    }

    func sessions(before: Date?, limit: Int) async throws -> SessionList {
        record("sessions")
        return try Fixture.decode(SessionList.self, "sessions_list")
    }

    func session(id: String) async throws -> SessionDetail {
        record("session \(id)")
        return try Fixture.decode(SessionDetail.self, "session_detail")
    }

    func questions(_ body: QuestionsRequest) async throws -> QuestionsResponse {
        record("questions")
        if let onQuestions { return try onQuestions(body) }
        return try Fixture.decode(QuestionsResponse.self, "questions_response")
    }

    func createPrompt(id: String, _ body: PromptCreateRequest) async throws -> Prompt {
        record("createPrompt \(id)")
        guard let onCreatePrompt else { throw APIError.notConfigured }
        return try onCreatePrompt(id, body)
    }

    func prompt(id: String) async throws -> PromptDetail {
        record("prompt \(id)")
        throw APIError.notConfigured
    }

    func uploadTake(
        id: String, metadata: TakeUploadMetadata, audioFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take {
        record("uploadTake \(id)")
        guard let onUpload else { throw APIError.notConfigured }
        await beforeUpload?(id)
        progress(0.5)
        progress(1)
        return try onUpload(id, metadata)
    }

    func take(id: String) async throws -> Take {
        record("take \(id)")
        if let onTake { return try onTake(id) }
        let next: Result<Take, APIError>? = lock.withLock {
            guard !_takeResponses.isEmpty else { return nil }
            return _takeResponses.count > 1 ? _takeResponses.removeFirst() : _takeResponses[0]
        }
        guard let next else { throw APIError.notConfigured }
        return try next.get()
    }

    func report(takeID: String) async throws -> TakeReport {
        record("report \(takeID)")
        if let onReport { return try onReport(takeID) }
        return try Fixture.decode(TakeReport.self, object: Fixture.fullReportObject())
    }

    func comparison(takeID: String) async throws -> Comparison {
        record("comparison \(takeID)")
        return try Fixture.decode(Comparison.self, "comparison")
    }

    func audio(takeID: String) async throws -> URL {
        record("audio \(takeID)")
        throw APIError.notConfigured
    }

    func reprocess(takeID: String, from stage: ReprocessStage) async throws -> Take {
        record("reprocess \(takeID) \(stage.rawValue)")
        guard let onReprocess else { throw APIError.notConfigured }
        return try onReprocess(takeID, stage)
    }
}

/// Take resources in a given state, built from the contract's example.
enum TakeFactory {
    static func take(
        id: String = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21", status: TakeStatus,
        coaching: CoachingStatus = .pending, error: (String, String)? = nil
    ) -> Take {
        var object = Fixture.object("take_uploaded")
        object["id"] = id
        object["status"] = status.rawValue
        object["coaching_status"] = coaching.rawValue
        object["error"] = error.map { ["code": $0.0, "message": $0.1] } ?? NSNull()
        return try! Fixture.decode(Take.self, object: object)
    }
}

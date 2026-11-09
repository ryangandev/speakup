import Foundation
import Testing
@testable import SpeakUp

/// Questions for a drive: prefetched and kept on the phone, with the built-in bank behind them.
@MainActor
struct DriveQuestionsTests {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "drive-questions-\(UUID().uuidString).json")

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [QuestionsRequest] = []
        var all: [QuestionsRequest] { lock.withLock { _all } }
        func append(_ request: QuestionsRequest) { lock.withLock { _all.append(request) } }
    }

    @Test func prefetchedQuestionsComeFirstAndOutliveTheApp() async throws {
        let api = FakeAPI()
        let requests = Requests()
        api.onQuestions = { request in
            requests.append(request)
            return try Fixture.decode(QuestionsResponse.self, "questions_response")
        }
        let questions = DriveQuestions(fileURL: file, api: { api })
        await questions.prefetch()

        #expect(requests.all.first?.count == DriveQuestions.batchSize)
        #expect(requests.all.first?.category == nil)
        #expect(questions.cached.count == 3)
        let first = try #require(questions.next())
        #expect(first.source == .claude)
        #expect(questions.cached.count == 2)

        // A drive that starts offline later still has the rest, and asks for what it lacks
        // without the question already asked.
        let later = DriveQuestions(fileURL: file, api: { api })
        #expect(later.cached.map(\.text) == questions.cached.map(\.text))
        await later.prefetch()
        let request = try #require(requests.all.last)
        #expect(request.count == DriveQuestions.batchSize - 2)
        #expect(request.exclude.contains(first.text))
    }

    @Test func offlineTheBankServesEveryQuestionOncePerDrive() async throws {
        let api = FakeAPI()
        api.onQuestions = { _ in throw APIError.transport(code: .notConnectedToInternet, message: "Offline.") }
        let questions = DriveQuestions(fileURL: nil, api: { api })
        await questions.prefetch()
        questions.beginDrive()

        var asked: [DriveQuestions.Item] = []
        while let item = questions.next() { asked.append(item) }

        #expect(asked.count == DriveQuestions.bank.count)
        #expect(Set(asked.map(\.text)).count == asked.count)
        #expect(asked.allSatisfy { $0.source == .bank })
        // The category changes from one question to the next.
        #expect(zip(asked, asked.dropFirst()).allSatisfy { $0.category != $1.category })

        // A new drive can ask them again, least recently asked first.
        questions.beginDrive()
        #expect(questions.next()?.text == asked.first?.text)
    }

    @Test func theBankIsImpromptuQuestionsInEveryCategory() {
        let categories = Set(DriveQuestions.bank.map(\.category))
        #expect(categories == [.decision, .status, .explain, .pushback, .other])
        #expect(DriveQuestions.bank.allSatisfy { !$0.text.isEmpty && $0.targetSeconds > 0 })
    }
}

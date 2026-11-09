import Foundation
import Testing
@testable import SpeakUp

/// The upload and polling state machine behind the Processing screen.
@MainActor
struct ProcessingControllerTests {
    let takeID = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"

    /// Records each sleep instead of waiting.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _sleeps: [Duration] = []
        var sleeps: [Duration] { lock.withLock { _sleeps } }
        func sleep(_ duration: Duration) { lock.withLock { _sleeps.append(duration) } }
    }

    private func controller(
        api: FakeAPI, needsUpload: Bool = true, clock: Clock = Clock(),
        upload: ProcessingController.Upload? = nil
    ) -> ProcessingController {
        let takeID = takeID
        return ProcessingController(
            takeID: takeID, api: api, needsUpload: needsUpload,
            upload: upload ?? { progress in try await api.uploadTake(
                id: takeID, metadata: try Fixture.decode(TakeUploadMetadata.self, "take_upload_metadata"),
                audioFile: URL(filePath: "/dev/null"), progress: progress) },
            sleep: { clock.sleep($0) })
    }

    @Test func phaseMapsEveryStatus() {
        #expect(ProcessingController.phase(for: TakeFactory.take(status: .uploaded)) == .processing(.uploaded))
        #expect(ProcessingController.phase(for: TakeFactory.take(status: .transcribing)) == .processing(.transcribing))
        #expect(ProcessingController.phase(for: TakeFactory.take(status: .analyzing)) == .processing(.analyzing))
        #expect(ProcessingController.phase(for: TakeFactory.take(status: .coaching)) == .processing(.coaching))
        let done = TakeFactory.take(status: .done, coaching: .done)
        #expect(ProcessingController.phase(for: done) == .done(done))
        let failed = TakeFactory.take(status: .failed, error: ("no_speech", "Fewer than 5 words were transcribed."))
        #expect(ProcessingController.phase(for: failed) == .failed(code: .noSpeech, message: "Fewer than 5 words were transcribed."))
        // An unknown status keeps polling.
        #expect(ProcessingController.phase(for: TakeFactory.take(status: TakeStatus(rawValue: "queued"))) == .processing(TakeStatus(rawValue: "queued")))
    }

    @Test func uploadsThenPollsEveryOneAndAHalfSecondsUntilDone() async {
        let api = FakeAPI()
        api.onUpload = { [takeID] _, _ in TakeFactory.take(id: takeID, status: .uploaded) }
        api.queueTakeResponses([
            .success(TakeFactory.take(status: .transcribing)),
            .success(TakeFactory.take(status: .analyzing)),
            .success(TakeFactory.take(status: .coaching)),
            .success(TakeFactory.take(status: .done, coaching: .done)),
        ])
        let clock = Clock()
        let controller = controller(api: api, clock: clock)
        #expect(controller.phase == .uploading(progress: 0))

        await controller.run()

        guard case .done(let take) = controller.phase else {
            Issue.record("Expected done, got \(controller.phase)")
            return
        }
        #expect(take.coachingStatus == .done)
        #expect(controller.processingStartedAt != nil)
        #expect(clock.sleeps == Array(repeating: .milliseconds(1500), count: 4))
        #expect(api.calls.filter { $0.hasPrefix("take ") }.count == 4)
    }

    @Test func uploadFailureKeepsTheTakeAndRetryUploadWorks() async {
        let api = FakeAPI()
        let attempts = Counter()
        api.onUpload = { [takeID] _, _ in
            if attempts.next() == 1 {
                throw APIError.transport(code: .notConnectedToInternet, message: "The Internet connection appears to be offline.")
            }
            return TakeFactory.take(id: takeID, status: .done, coaching: .unavailable)
        }
        let controller = controller(api: api)

        await controller.run()
        guard case .uploadFailed(let message) = controller.phase else {
            Issue.record("Expected uploadFailed, got \(controller.phase)")
            return
        }
        #expect(message.contains("Can't reach the server"))
        #expect(controller.phase.isTerminal)

        controller.retryUpload()
        #expect(controller.phase == .uploading(progress: 0))
        // retryUpload runs the upload in its own task; wait for it to land.
        for _ in 0..<1_000 where !controller.phase.isTerminal {
            await Task.yield()
        }
        #expect(attempts.next() == 3)
        guard case .done(let take) = controller.phase else {
            Issue.record("Expected done, got \(controller.phase)")
            return
        }
        #expect(take.coachingStatus == .unavailable)
    }

    @Test func noSpeechEndsInFailedWithItsCode() async {
        let api = FakeAPI()
        api.onUpload = { [takeID] _, _ in TakeFactory.take(id: takeID, status: .uploaded) }
        api.queueTakeResponses([
            .success(TakeFactory.take(status: .transcribing)),
            .success(TakeFactory.take(status: .failed, error: ("no_speech", "Fewer than 5 words were transcribed."))),
        ])
        let controller = controller(api: api)
        await controller.run()
        #expect(controller.phase == .failed(code: .noSpeech, message: "Fewer than 5 words were transcribed."))
    }

    @Test func pollErrorsAreShownAndPollingContinues() async {
        let api = FakeAPI()
        api.queueTakeResponses([
            .failure(.transport(code: .timedOut, message: "The request timed out.")),
            .failure(.server(status: 500, code: "internal", message: "Something went wrong.", details: nil)),
            .success(TakeFactory.take(status: .analyzing)),
            .success(TakeFactory.take(status: .done, coaching: .done)),
        ])
        let clock = Clock()
        let controller = controller(api: api, needsUpload: false, clock: clock)
        #expect(controller.phase == .processing(.uploaded))
        await controller.run()
        guard case .done = controller.phase else {
            Issue.record("Expected done, got \(controller.phase)")
            return
        }
        #expect(controller.connectionIssue == nil)
        #expect(clock.sleeps.count == 4)
    }

    @Test func tryAgainReprocessesFromTranscribing() async {
        let api = FakeAPI()
        api.onReprocess = { id, stage in
            #expect(stage == .transcribing)
            return TakeFactory.take(id: id, status: .transcribing)
        }
        api.queueTakeResponses([.success(TakeFactory.take(status: .done, coaching: .done))])
        let controller = controller(api: api, needsUpload: false)
        await controller.reprocessAndPoll(from: .transcribing)
        #expect(api.calls.first == "reprocess \(takeID) transcribing")
        guard case .done = controller.phase else {
            Issue.record("Expected done, got \(controller.phase)")
            return
        }
    }

    @Test func reprocessRejectedShowsTheReason() async {
        let api = FakeAPI()
        api.onReprocess = { _, _ in
            throw APIError.server(status: 409, code: "invalid_state", message: "The take is still processing.", details: nil)
        }
        let controller = controller(api: api, needsUpload: false)
        await controller.reprocessAndPoll(from: .coaching)
        #expect(controller.connectionIssue == "The take is still processing.")
    }

    @Test func slowAfterThreeMinutes() async {
        let api = FakeAPI()
        api.queueTakeResponses([.success(TakeFactory.take(status: .transcribing))])
        let start = Date()
        let controller = ProcessingController(
            takeID: takeID, api: api, needsUpload: false, upload: { _ in throw APIError.notConfigured },
            sleep: { _ in throw CancellationError() }, now: { start })
        #expect(!controller.isSlow(at: start.addingTimeInterval(179)))
        #expect(controller.isSlow(at: start.addingTimeInterval(180)))
    }

    @Test func cancelledSleepStopsPolling() async {
        let api = FakeAPI()
        api.queueTakeResponses([.success(TakeFactory.take(status: .transcribing))])
        let controller = ProcessingController(
            takeID: takeID, api: api, needsUpload: false, upload: { _ in throw APIError.notConfigured },
            sleep: { _ in throw CancellationError() })
        await controller.run()
        #expect(controller.phase == .processing(.uploaded))
        #expect(api.calls.isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

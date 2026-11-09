import Foundation
import Observation

/// The take's journey after Done: upload, then poll `GET /v1/takes/{id}` every 1.5 seconds
/// until the take is `done` or `failed` (architecture.md#why-the-app-polls).
///
/// The phases map one to one to what the Processing screen shows (product.md#processing).
/// Polling errors do not end the loop: the server may be restarting or the phone may have
/// dropped off the tailnet for a moment, so the screen notes the problem and keeps trying.
@MainActor
@Observable
final class ProcessingController {
    enum Phase: Equatable, Sendable {
        case uploading(progress: Double)
        /// The take is saved on this phone; the user can retry the upload.
        case uploadFailed(message: String)
        case processing(TakeStatus)
        case done(Take)
        case failed(code: TakeErrorCode, message: String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .uploadFailed: return true
            case .uploading, .processing: return false
            }
        }
    }

    typealias Upload = @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Take
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let pollInterval: Duration = .milliseconds(1500)
    /// After this long the screen adds "Taking longer than usual".
    static var slowAfter: TimeInterval = 3 * 60

    let takeID: String
    private(set) var phase: Phase
    /// When server processing started, for the elapsed time on screen.
    private(set) var processingStartedAt: Date?
    /// The last polling error, cleared by the next successful poll.
    private(set) var connectionIssue: String?

    private let api: any SpeakUpAPI
    private let upload: Upload
    private let sleep: Sleep
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var isDetached = false

    init(
        takeID: String, api: any SpeakUpAPI, needsUpload: Bool, upload: @escaping Upload,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping () -> Date = Date.init
    ) {
        self.takeID = takeID
        self.api = api
        self.upload = upload
        self.sleep = sleep
        self.now = now
        phase = needsUpload ? .uploading(progress: 0) : .processing(.uploaded)
        if !needsUpload { processingStartedAt = now() }
    }

    /// Maps a Take resource to the phase the screen shows.
    static func phase(for take: Take) -> Phase {
        switch take.status {
        case .done:
            return .done(take)
        case .failed:
            return .failed(
                code: take.error?.code ?? .analysisFailed,
                message: take.error?.message ?? "Processing failed.")
        default:
            return .processing(take.status)
        }
    }

    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Leaves the screen: an upload in flight finishes, but nothing is polled afterwards.
    func detach() {
        if case .uploading = phase {
            isDetached = true
        } else {
            stop()
        }
    }

    func retryUpload() {
        guard case .uploadFailed = phase else { return }
        phase = .uploading(progress: 0)
        start()
    }

    /// "Try again" on a failed take: reprocess from the start, then poll.
    func tryAgain() {
        guard case .failed = phase else { return }
        task?.cancel()
        task = Task { await reprocessAndPoll(from: .transcribing) }
    }

    /// Runs the upload when needed, then polls until a terminal phase. Tests call this directly.
    func run() async {
        if case .uploading = phase {
            do {
                let take = try await upload { [weak self] fraction in
                    Task { @MainActor in self?.setUploadProgress(fraction) }
                }
                processingStartedAt = now()
                phase = Self.phase(for: take)
            } catch {
                phase = .uploadFailed(message: APIError.wrap(error).userMessage)
                return
            }
        }
        guard !isDetached else { return }
        await poll()
    }

    func reprocessAndPoll(from stage: ReprocessStage) async {
        do {
            let take = try await api.reprocess(takeID: takeID, from: stage)
            processingStartedAt = now()
            connectionIssue = nil
            phase = Self.phase(for: take)
        } catch {
            connectionIssue = APIError.wrap(error).userMessage
            return
        }
        await poll()
    }

    private func poll() async {
        while !phase.isTerminal {
            do {
                try await sleep(Self.pollInterval)
            } catch {
                return
            }
            if Task.isCancelled { return }
            do {
                let take = try await api.take(id: takeID)
                connectionIssue = nil
                phase = Self.phase(for: take)
            } catch {
                connectionIssue = APIError.wrap(error).userMessage
            }
        }
    }

    private func setUploadProgress(_ fraction: Double) {
        guard case .uploading(let current) = phase, fraction > current else { return }
        phase = .uploading(progress: fraction)
    }

    func isSlow(at date: Date) -> Bool {
        guard let processingStartedAt, case .processing = phase else { return false }
        return date.timeIntervalSince(processingStartedAt) >= Self.slowAfter
    }
}

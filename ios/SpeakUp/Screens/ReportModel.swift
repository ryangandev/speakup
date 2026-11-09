import Foundation
import Observation

/// Where a Report or Comparison was opened from, which decides its actions and where links push.
enum ReportContext: Hashable {
    /// From Practice: Retry, Next prompt and End session are available for the open session.
    case practice
    /// From History: reading only.
    case history
}

/// Loads a take's report, its comparison card, and the session's nervousness ratings,
/// and runs "Get coaching" and "Try coaching again".
@MainActor
@Observable
final class ReportModel {
    let takeID: String
    private(set) var report: TakeReport?
    private(set) var comparison: Comparison?
    private(set) var ratings: (before: Int?, after: Int?, isOpen: Bool)?
    private(set) var errorMessage: String?
    /// Why the last Get coaching or Try coaching again did not finish.
    private(set) var coachingError: String?
    private(set) var isLoading = false
    /// Polls the take while coaching runs (after Get coaching, or when opened mid-coaching).
    private(set) var coachingController: ProcessingController?
    private var coachingWatch: Task<Void, Never>?

    init(takeID: String) {
        self.takeID = takeID
    }

    func load(app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        let api = app.api
        do {
            let report = try await api.report(takeID: takeID)
            self.report = report
            errorMessage = nil
            if report.take.status == .coaching { watchCoaching(app: app, reprocess: false) }
            await loadComparison(api: api, report: report)
            await loadRatings(app: app, sessionID: report.take.sessionId)
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }

    private func loadComparison(api: any SpeakUpAPI, report: TakeReport) async {
        guard report.hasComparison, report.take.attempt > 1 else {
            comparison = nil
            return
        }
        // 404 no_previous_take and 409 not_ready just mean there is no card yet.
        comparison = try? await api.comparison(takeID: takeID)
    }

    private func loadRatings(app: AppModel, sessionID: String) async {
        if let local = app.store.session(id: sessionID) {
            ratings = (local.nervousnessBefore, local.nervousnessAfter, local.isOpen)
        } else if let detail = try? await app.api.session(id: sessionID) {
            ratings = (
                detail.session.nervousnessBefore, detail.session.nervousnessAfter,
                detail.session.endedAt == nil
            )
        }
    }

    var isCoachingRunning: Bool {
        guard let phase = coachingController?.phase else { return false }
        return !phase.isTerminal
    }

    /// "Get coaching" and "Try coaching again": reprocess from coaching, poll, reload.
    func requestCoaching(app: AppModel) {
        watchCoaching(app: app, reprocess: true)
    }

    private func watchCoaching(app: AppModel, reprocess: Bool) {
        coachingWatch?.cancel()
        coachingError = nil
        let controller = ProcessingController(
            takeID: takeID, api: app.api, needsUpload: false, upload: { _ in
                throw APIError.notConfigured
            })
        coachingController = controller
        coachingWatch = Task {
            if reprocess {
                await controller.reprocessAndPoll(from: .coaching)
            } else {
                await controller.run()
            }
            guard !Task.isCancelled else { return }
            coachingController = nil
            switch controller.phase {
            case .done:
                coachingError = nil
                await load(app: app)
            case .failed(_, let message):
                coachingError = message
            default:
                coachingError = controller.connectionIssue ?? "Coaching could not be started."
            }
        }
    }

    func stop() {
        coachingWatch?.cancel()
        coachingWatch = nil
    }
}

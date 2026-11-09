import Foundation
import UIKit

/// Sends what the phone has to the server, in the order the server needs it: the session,
/// then the prompt, then the take. Every create is an idempotent `PUT` with an id the app
/// made, so repeating any step after a lost response is harmless.
@MainActor
final class TakeSync {
    /// Runs work that should finish even if the app goes to the background meanwhile.
    typealias BackgroundWork = @MainActor (_ name: String, _ work: () async throws -> Take) async throws -> Take

    private let store: PracticeStore
    private let api: () -> any SpeakUpAPI
    private let inBackground: BackgroundWork

    init(
        store: PracticeStore, api: @escaping () -> any SpeakUpAPI,
        inBackground: @escaping BackgroundWork = TakeSync.withBackgroundTime
    ) {
        self.store = store
        self.api = api
        self.inBackground = inBackground
    }

    /// Asks iOS for time to finish when the user locks the phone right after Done; without
    /// it the upload dies on suspend.
    static func withBackgroundTime(_ name: String, _ work: () async throws -> Take) async throws -> Take {
        let application = UIApplication.shared
        let id = application.beginBackgroundTask(withName: name)
        defer { if id != .invalid { application.endBackgroundTask(id) } }
        return try await work()
    }

    /// Uploads one take, creating its session and prompt first when needed. A failure is
    /// recorded on the take, so Home can show it, and rethrown.
    ///
    /// A take the server already has is not sent again, and when another upload of the same
    /// take is in flight (the background sync, say) this waits for it instead of failing.
    func upload(takeID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Take {
        while store.uploadingTakeIDs.contains(takeID) {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let take = store.take(id: takeID) else {
            throw APIError.local("The take is not on this phone.")
        }
        if take.isUploaded, let remote = take.remote { return remote }
        store.uploadingTakeIDs.insert(takeID)
        defer { store.uploadingTakeIDs.remove(takeID) }
        do {
            let remote = try await inBackground("Upload take") {
                try await self.createParentsAndUpload(takeID: takeID, progress: progress)
            }
            store.update(remote: remote)
            return remote
        } catch {
            store.setUploadError(APIError.wrap(error).userMessage, takeID: takeID)
            throw error
        }
    }

    /// One pass, and a second one when the server turned out not to know the session or
    /// prompt the phone thought it had created (Settings now points at a rebuilt server, say).
    private func createParentsAndUpload(
        takeID: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take {
        var recreated = false
        while true {
            do {
                return try await uploadOnce(takeID: takeID, progress: progress)
            } catch let error as MissingParent where !recreated {
                recreated = true
                switch error {
                case .session(let id): store.markSessionMissing(id)
                case .prompt(let id): store.markPromptMissing(id)
                }
            } catch let error as MissingParent {
                throw error.apiError
            }
        }
    }

    private enum MissingParent: Error {
        case session(String)
        case prompt(String)

        var apiError: APIError {
            switch self {
            case .session: return .local("The server does not know this take's session.")
            case .prompt: return .local("The server does not know this take's prompt.")
            }
        }
    }

    private func uploadOnce(
        takeID: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take {
        guard let take = store.take(id: takeID) else {
            throw APIError.local("The take is not on this phone.")
        }
        let api = api()
        if let session = store.session(id: take.sessionId), !session.isCreated {
            _ = try await api.createSession(id: session.id, session.createRequest)
            store.markSessionCreated(session.id)
        }
        if let prompt = store.prompt(id: take.promptId), !prompt.isCreated {
            do {
                _ = try await api.createPrompt(id: prompt.id, prompt.createRequest)
            } catch let error as APIError where error.missingParentField != nil {
                // The only parent a prompt names is its session.
                throw MissingParent.session(take.sessionId)
            }
            store.markPromptCreated(prompt.id)
        }
        guard let audio = store.audioURL(takeID: takeID) else {
            throw APIError.local("The recording is missing from this phone.")
        }
        do {
            return try await api.uploadTake(
                id: takeID, metadata: take.metadata, audioFile: audio, progress: progress)
        } catch let error as APIError {
            switch error.missingParentField {
            case "session_id": throw MissingParent.session(take.sessionId)
            case .some: throw MissingParent.prompt(take.promptId)
            case nil: throw error
            }
        }
    }

    /// Ends a session on the server once it exists there.
    func sendEnd(sessionID: String) async throws {
        guard let session = store.session(id: sessionID), let endedAt = session.endedAt,
            session.isCreated, !session.isEndSent
        else { return }
        let api = api()
        let body = SessionEndRequest(endedAt: endedAt, nervousnessAfter: session.nervousnessAfter)
        do {
            _ = try await api.endSession(id: sessionID, body)
        } catch let error as APIError where error.code == "not_found" {
            // The server lost the session: create it again with the same id, then end it.
            _ = try await api.createSession(id: sessionID, session.createRequest)
            _ = try await api.endSession(id: sessionID, body)
        }
        store.markEndSent(sessionID)
    }

    /// Uploads waiting takes, oldest first, and sends waiting session ends.
    ///
    /// A failure that is about one take (the server rejected it) is recorded on that take and
    /// the queue moves on, so one bad take never blocks the others. A failure that would hit
    /// every request (no connection, a rejected token) stops the pass.
    func syncPending() async {
        for take in store.pendingUploads where !store.uploadingTakeIDs.contains(take.id) {
            do {
                _ = try await upload(takeID: take.id, progress: { _ in })
            } catch {
                if APIError.wrap(error).affectsEveryRequest { return }
            }
        }
        for session in store.sessions where !session.isOpen && !session.isEndSent {
            do {
                try await sendEnd(sessionID: session.id)
            } catch {
                if APIError.wrap(error).affectsEveryRequest { return }
            }
        }
        store.pruneFinishedSessions()
    }

    /// Refreshes the server status of the open session's takes that are still processing.
    func refreshOpenSessionTakes() async {
        guard let session = store.openSession else { return }
        let api = api()
        for take in session.takes where take.isUploaded && !(take.remote?.status.isFinal ?? false) {
            if let remote = try? await api.take(id: take.id) {
                store.update(remote: remote)
            }
        }
    }
}

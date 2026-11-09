import Foundation

/// Sends what the phone has to the server, in the order the server needs it: the session,
/// then the prompt, then the take. Every create is an idempotent `PUT` with an id the app
/// made, so repeating any step after a lost response is harmless.
@MainActor
final class TakeSync {
    private let store: PracticeStore
    private let api: () -> any SpeakUpAPI

    init(store: PracticeStore, api: @escaping () -> any SpeakUpAPI) {
        self.store = store
        self.api = api
    }

    /// Uploads one take, creating its session and prompt first when needed.
    func upload(takeID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Take {
        guard let take = store.take(id: takeID) else {
            throw APIError.decoding("The take \(takeID) is not on this phone.")
        }
        guard !store.uploadingTakeIDs.contains(takeID) else {
            throw APIError.transport(code: .cancelled, message: "This take is already uploading.")
        }
        store.uploadingTakeIDs.insert(takeID)
        defer { store.uploadingTakeIDs.remove(takeID) }

        let api = api()
        if let session = store.session(id: take.sessionId), !session.isCreated {
            _ = try await api.createSession(id: session.id, session.createRequest)
            store.markSessionCreated(session.id)
        }
        if let prompt = store.prompt(id: take.promptId), !prompt.isCreated {
            _ = try await api.createPrompt(id: prompt.id, prompt.createRequest)
            store.markPromptCreated(prompt.id)
        }
        guard let audio = store.audioURL(takeID: takeID) else {
            throw APIError.transport(
                code: .fileDoesNotExist, message: "The recording is missing from this phone.")
        }
        let remote = try await api.uploadTake(
            id: takeID, metadata: take.metadata, audioFile: audio, progress: progress)
        store.update(remote: remote)
        return remote
    }

    /// Ends a session on the server once it exists there.
    func sendEnd(sessionID: String) async throws {
        guard let session = store.session(id: sessionID), let endedAt = session.endedAt,
            session.isCreated, !session.isEndSent
        else { return }
        _ = try await api().endSession(
            id: sessionID,
            SessionEndRequest(endedAt: endedAt, nervousnessAfter: session.nervousnessAfter))
        store.markEndSent(sessionID)
    }

    /// Uploads waiting takes and sends waiting session ends; stops at the first failure,
    /// since the next one would most likely fail the same way.
    func syncPending() async {
        for take in store.pendingUploads where !store.uploadingTakeIDs.contains(take.id) {
            do {
                _ = try await upload(takeID: take.id, progress: { _ in })
            } catch {
                return
            }
        }
        for session in store.sessions where !session.isOpen && !session.isEndSent {
            do {
                try await sendEnd(sessionID: session.id)
            } catch {
                return
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

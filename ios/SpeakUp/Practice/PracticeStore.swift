import Foundation
import Observation
import os

// What the phone keeps: the open session, its prompts, and every take until the server
// has it. The server is the source of truth for everything uploaded; this store exists so
// a take is saved on the phone before it is uploaded (product.md#recording) and so ids,
// attempts and session state survive a relaunch.
//
// practice.json outlives app updates, so every field with a default is decoded with
// `decodeIfPresent` in the `init(from:)` below its type: a field added later must not make
// an older file unreadable. Give any new field a default and decode it the same way.

struct LocalSession: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let mode: SessionMode
    let startedAt: Date
    let nervousnessBefore: Int?
    var endedAt: Date?
    var nervousnessAfter: Int?
    /// The server has the session (`PUT` succeeded).
    var isCreated = false
    /// The server has `ended_at` (`PATCH` succeeded).
    var isEndSent = false
    var prompts: [LocalPrompt] = []
    var takes: [LocalTake] = []

    var isOpen: Bool { endedAt == nil }

    var createRequest: SessionCreateRequest {
        SessionCreateRequest(mode: mode, startedAt: startedAt, nervousnessBefore: nervousnessBefore)
    }

    /// When the last take ended, for closing a stale session.
    var lastTakeEnd: Date? {
        takes.map { $0.recordedAt.addingTimeInterval($0.durationS) }.max()
    }
}

struct LocalPrompt: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let kind: PromptKind
    let text: String
    let notes: String?
    let category: PromptCategory?
    let targetSeconds: Int
    let questionSource: QuestionSource
    let createdAt: Date
    var isCreated = false

    var createRequest: PromptCreateRequest {
        PromptCreateRequest(
            sessionId: sessionId, kind: kind, text: text, notes: notes, category: category,
            targetSeconds: targetSeconds, questionSource: questionSource)
    }
}

struct LocalTake: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let promptId: String
    let sessionId: String
    let attempt: Int
    let recordedAt: Date
    let durationS: Double
    let micRoute: MicRoute
    let audioSha256: String
    let audioFileName: String
    /// The server has the audio.
    var isUploaded = false
    /// Why the last upload attempt failed, shown on Home until an upload succeeds.
    var uploadError: String?
    /// The latest Take resource the app has seen.
    var remote: Take?

    var metadata: TakeUploadMetadata {
        TakeUploadMetadata(
            promptId: promptId, attempt: attempt, recordedAt: recordedAt, durationS: durationS,
            audioSha256: audioSha256, micRoute: micRoute)
    }
}

@MainActor
@Observable
final class PracticeStore {
    /// An open session closes itself this long after its last take (product.md#sessions-in-the-app).
    static let staleAfter: TimeInterval = 2 * 60 * 60

    private(set) var sessions: [LocalSession] = []
    /// Takes with an upload in flight, so two screens never upload the same take at once.
    var uploadingTakeIDs: Set<String> = []

    let directory: URL
    private var stateFile: URL { directory.appending(path: "practice.json") }
    var takesDirectory: URL { directory.appending(path: "Takes", directoryHint: .isDirectory) }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SpeakUp", directoryHint: .isDirectory)
    }

    // MARK: Reading

    var openSession: LocalSession? { sessions.first { $0.isOpen } }

    func session(id: String) -> LocalSession? { sessions.first { $0.id == id } }

    func prompt(id: String) -> LocalPrompt? {
        for session in sessions {
            if let prompt = session.prompts.first(where: { $0.id == id }) { return prompt }
        }
        return nil
    }

    func take(id: String) -> LocalTake? {
        for session in sessions {
            if let take = session.takes.first(where: { $0.id == id }) { return take }
        }
        return nil
    }

    func audioURL(takeID: String) -> URL? {
        guard let take = take(id: takeID) else { return nil }
        let url = takesDirectory.appending(path: take.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where a new recording is written before it is kept.
    func newRecordingURL(takeID: String) -> URL {
        takesDirectory.appending(path: "\(takeID).wav")
    }

    /// Takes waiting for upload, oldest first, so a retry's previous take goes first.
    var pendingUploads: [LocalTake] {
        sessions.flatMap(\.takes).filter { !$0.isUploaded }.sorted { $0.recordedAt < $1.recordedAt }
    }

    // MARK: Writing

    @discardableResult
    func openNewSession(nervousnessBefore: Int?, now: Date = Date()) -> LocalSession {
        let session = LocalSession(
            id: IDs.make(), mode: .home, startedAt: now, nervousnessBefore: nervousnessBefore)
        sessions.append(session)
        save()
        return session
    }

    @discardableResult
    func addPrompt(
        sessionID: String, kind: PromptKind, text: String, notes: String?,
        category: PromptCategory?, targetSeconds: Int, questionSource: QuestionSource,
        now: Date = Date()
    ) -> LocalPrompt? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let prompt = LocalPrompt(
            id: IDs.make(), sessionId: sessionID, kind: kind, text: text,
            notes: kind == .prepared ? notes : nil, category: kind == .impromptu ? category : nil,
            targetSeconds: targetSeconds, questionSource: questionSource, createdAt: now)
        sessions[index].prompts.append(prompt)
        save()
        return prompt
    }

    /// Keeps a finished recording as the prompt's next attempt.
    @discardableResult
    func keepTake(
        id: String, promptID: String, recording: AudioRecorder.Recording, sha256: String
    ) -> LocalTake? {
        guard
            let index = sessions.firstIndex(where: { $0.prompts.contains { $0.id == promptID } })
        else { return nil }
        let attempt = (sessions[index].takes.filter { $0.promptId == promptID }.map(\.attempt).max() ?? 0) + 1
        let take = LocalTake(
            id: id, promptId: promptID, sessionId: sessions[index].id, attempt: attempt,
            recordedAt: recording.recordedAt, durationS: (recording.duration * 1000).rounded() / 1000,
            micRoute: recording.micRoute, audioSha256: sha256,
            audioFileName: recording.url.lastPathComponent)
        sessions[index].takes.append(take)
        save()
        return take
    }

    func markSessionCreated(_ id: String) {
        mutateSession(id) { $0.isCreated = true }
    }

    /// The server does not know the session (it was rebuilt, or Settings points at another
    /// one): create it and its prompts again on the next upload, with the same ids.
    func markSessionMissing(_ id: String) {
        mutateSession(id) { session in
            session.isCreated = false
            session.isEndSent = false
            for index in session.prompts.indices { session.prompts[index].isCreated = false }
        }
    }

    /// The server does not know the prompt: create it again on the next upload.
    func markPromptMissing(_ id: String) {
        for index in sessions.indices {
            if let promptIndex = sessions[index].prompts.firstIndex(where: { $0.id == id }) {
                sessions[index].prompts[promptIndex].isCreated = false
            }
        }
        save()
    }

    func setUploadError(_ message: String?, takeID: String) {
        for index in sessions.indices {
            if let takeIndex = sessions[index].takes.firstIndex(where: { $0.id == takeID }),
                sessions[index].takes[takeIndex].uploadError != message
            {
                sessions[index].takes[takeIndex].uploadError = message
                save()
            }
        }
    }

    func markPromptCreated(_ id: String) {
        for index in sessions.indices {
            if let promptIndex = sessions[index].prompts.firstIndex(where: { $0.id == id }) {
                sessions[index].prompts[promptIndex].isCreated = true
            }
        }
        save()
    }

    func update(remote take: Take) {
        for index in sessions.indices {
            if let takeIndex = sessions[index].takes.firstIndex(where: { $0.id == take.id }) {
                sessions[index].takes[takeIndex].isUploaded = true
                sessions[index].takes[takeIndex].uploadError = nil
                sessions[index].takes[takeIndex].remote = take
            }
        }
        save()
    }

    /// Ends a session on the phone; `TakeSync` sends it to the server.
    func endSession(_ id: String, endedAt: Date, nervousnessAfter: Int?) {
        mutateSession(id) {
            guard $0.isOpen else { return }
            $0.endedAt = endedAt
            $0.nervousnessAfter = nervousnessAfter
        }
    }

    func markEndSent(_ id: String) {
        mutateSession(id) { $0.isEndSent = true }
    }

    /// Closes the open session when its last take ended more than two hours ago, with no
    /// after-rating and `ended_at` at the end of its last take. A session without takes
    /// closes at its start.
    func closeStaleSession(now: Date = Date()) {
        guard let session = openSession else { return }
        let lastActivity = session.lastTakeEnd ?? session.startedAt
        guard now.timeIntervalSince(lastActivity) > Self.staleAfter else { return }
        endSession(session.id, endedAt: lastActivity, nervousnessAfter: nil)
    }

    /// Drops closed sessions the server has in full, and closed sessions that never had a
    /// take (the server never heard of them). Audio files stay for local playback until the
    /// session is dropped.
    func pruneFinishedSessions() {
        let finished = sessions.filter { session in
            guard !session.isOpen else { return false }
            if session.takes.isEmpty { return true }
            return session.isEndSent && session.takes.allSatisfy(\.isUploaded)
        }
        guard !finished.isEmpty else { return }
        for session in finished {
            for take in session.takes {
                try? FileManager.default.removeItem(at: takesDirectory.appending(path: take.audioFileName))
            }
        }
        let ids = Set(finished.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        sessions = []
        try? FileManager.default.removeItem(at: directory)
        canSave = true
        save()
    }

    private func mutateSession(_ id: String, _ change: (inout LocalSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        save()
    }

    // MARK: Persistence

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "PracticeStore")
    /// False when practice.json exists but could not be read, so a save would replace takes
    /// the phone still has with an empty list.
    private var canSave = true

    private func load() {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: stateFile)
        } catch {
            // Most likely the file is still protected (before the first unlock). Keep it and
            // do not save over it this launch.
            Self.log.error("Could not read practice.json: \(error.localizedDescription, privacy: .public)")
            canSave = false
            return
        }
        do {
            sessions = try JSONCoding.decoder().decode([LocalSession].self, from: data)
        } catch {
            // Never overwrite a file that does not decode: it holds the metadata of takes
            // that may not be uploaded yet. Move it aside and start empty.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appending(path: "practice.corrupt-\(stamp).json")
            Self.log.error(
                "practice.json did not decode, moved to \(aside.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            do {
                try FileManager.default.moveItem(at: stateFile, to: aside)
            } catch {
                Self.log.error("Could not move practice.json aside: \(error.localizedDescription, privacy: .public)")
                canSave = false
            }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONCoding.encoder().encode(sessions)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            assertionFailure("Could not save practice state: \(error)")
        }
    }
}

// MARK: Decoding older files

extension LocalSession {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        mode = try container.decode(SessionMode.self, forKey: .mode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        nervousnessBefore = try container.decodeIfPresent(Int.self, forKey: .nervousnessBefore)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        nervousnessAfter = try container.decodeIfPresent(Int.self, forKey: .nervousnessAfter)
        isCreated = try container.decodeIfPresent(Bool.self, forKey: .isCreated) ?? false
        isEndSent = try container.decodeIfPresent(Bool.self, forKey: .isEndSent) ?? false
        prompts = try container.decodeIfPresent([LocalPrompt].self, forKey: .prompts) ?? []
        takes = try container.decodeIfPresent([LocalTake].self, forKey: .takes) ?? []
    }
}

extension LocalPrompt {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        kind = try container.decode(PromptKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        category = try container.decodeIfPresent(PromptCategory.self, forKey: .category)
        targetSeconds = try container.decode(Int.self, forKey: .targetSeconds)
        questionSource = try container.decode(QuestionSource.self, forKey: .questionSource)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isCreated = try container.decodeIfPresent(Bool.self, forKey: .isCreated) ?? false
    }
}

extension LocalTake {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        promptId = try container.decode(String.self, forKey: .promptId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        attempt = try container.decode(Int.self, forKey: .attempt)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        durationS = try container.decode(Double.self, forKey: .durationS)
        micRoute = try container.decode(MicRoute.self, forKey: .micRoute)
        audioSha256 = try container.decode(String.self, forKey: .audioSha256)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        isUploaded = try container.decodeIfPresent(Bool.self, forKey: .isUploaded) ?? false
        uploadError = try container.decodeIfPresent(String.self, forKey: .uploadError)
        // A Take shape the app no longer understands is dropped, not fatal: the next poll
        // fetches it again.
        remote = try? container.decodeIfPresent(Take.self, forKey: .remote)
    }
}

import Foundation

// Resources of the server API (architecture.md#domain-model and #server-api).
// Property names are the camelCase form of the contract's snake_case keys; the coders in
// `JSONCoding` convert between them.

// MARK: - Enums

struct SessionMode: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let home = Self(rawValue: "home")
    static let driving = Self(rawValue: "driving")
}

struct PromptKind: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let prepared = Self(rawValue: "prepared")
    static let impromptu = Self(rawValue: "impromptu")
}

struct PromptCategory: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let decision = Self(rawValue: "decision")
    static let status = Self(rawValue: "status")
    static let explain = Self(rawValue: "explain")
    static let pushback = Self(rawValue: "pushback")
    static let other = Self(rawValue: "other")
}

struct QuestionSource: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let typed = Self(rawValue: "typed")
    static let claude = Self(rawValue: "claude")
    static let bank = Self(rawValue: "bank")
}

/// The language Ryan speaks in a take: English, or Mandarin Chinese.
struct SpeechLanguage: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let english = Self(rawValue: "en")
    static let chinese = Self(rawValue: "zh")

    static let choices: [SpeechLanguage] = [.english, .chinese]

    var label: String {
        switch self {
        case .chinese: return "中文"
        default: return "English"
        }
    }
}

struct TakeStatus: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let uploaded = Self(rawValue: "uploaded")
    static let transcribing = Self(rawValue: "transcribing")
    static let analyzing = Self(rawValue: "analyzing")
    static let coaching = Self(rawValue: "coaching")
    static let done = Self(rawValue: "done")
    static let failed = Self(rawValue: "failed")

    /// `done` and `failed` end processing; anything else, including an unknown status,
    /// means the server is still working, so the app keeps polling.
    var isFinal: Bool { self == .done || self == .failed }
}

struct CoachingStatus: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let pending = Self(rawValue: "pending")
    static let done = Self(rawValue: "done")
    static let unavailable = Self(rawValue: "unavailable")
    static let failed = Self(rawValue: "failed")
}

struct TakeErrorCode: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let audioInvalid = Self(rawValue: "audio_invalid")
    static let noSpeech = Self(rawValue: "no_speech")
    static let sttFailed = Self(rawValue: "stt_failed")
    static let analysisFailed = Self(rawValue: "analysis_failed")
}

/// The iOS input port type, as the upload metadata names it.
struct MicRoute: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let builtIn = Self(rawValue: "built_in")
    static let bluetoothHFP = Self(rawValue: "bluetooth_hfp")
    static let carAudio = Self(rawValue: "car_audio")
    static let headset = Self(rawValue: "headset")
    static let usb = Self(rawValue: "usb")
    static let other = Self(rawValue: "other")
}

struct ReprocessStage: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let transcribing = Self(rawValue: "transcribing")
    static let analyzing = Self(rawValue: "analyzing")
    static let coaching = Self(rawValue: "coaching")
}

// MARK: - Session

struct Session: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let mode: SessionMode
    let startedAt: Date
    let endedAt: Date?
    let nervousnessBefore: Int?
    let nervousnessAfter: Int?
    let createdAt: Date
    let updatedAt: Date
}

/// One row of `GET /v1/sessions`: the Session resource plus prompt summaries and a take count.
struct SessionListItem: Decodable, Hashable, Sendable, Identifiable {
    let session: Session
    let prompts: [PromptSummary]
    let takeCount: Int

    var id: String { session.id }

    private enum CodingKeys: String, CodingKey { case prompts, takeCount }

    init(from decoder: Decoder) throws {
        session = try Session(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try container.decode([PromptSummary].self, forKey: .prompts)
        takeCount = try container.decode(Int.self, forKey: .takeCount)
    }
}

struct PromptSummary: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let kind: PromptKind
    let text: String
    let takeCount: Int
}

struct SessionList: Decodable, Sendable {
    let sessions: [SessionListItem]
    let nextBefore: Date?
}

/// `GET /v1/sessions/{id}`: the Session resource plus its prompts, each with its takes.
struct SessionDetail: Decodable, Hashable, Sendable, Identifiable {
    let session: Session
    let prompts: [PromptDetail]

    var id: String { session.id }

    private enum CodingKeys: String, CodingKey { case prompts }

    init(from decoder: Decoder) throws {
        session = try Session(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try container.decode([PromptDetail].self, forKey: .prompts)
    }
}

// MARK: - Prompt

struct Prompt: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let sessionId: String
    let kind: PromptKind
    let text: String
    let notes: String?
    let category: PromptCategory?
    let targetSeconds: Int
    let questionSource: QuestionSource
    let language: SpeechLanguage
    let createdAt: Date
}

extension Prompt {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, kind, text, notes, category, targetSeconds, questionSource, language, createdAt
    }

    /// A server from before `language` sends none, which means English.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        kind = try container.decode(PromptKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        category = try container.decodeIfPresent(PromptCategory.self, forKey: .category)
        targetSeconds = try container.decode(Int.self, forKey: .targetSeconds)
        questionSource = try container.decode(QuestionSource.self, forKey: .questionSource)
        language = try container.decodeIfPresent(SpeechLanguage.self, forKey: .language) ?? .english
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// The Prompt resource plus `takes`, by attempt.
struct PromptDetail: Decodable, Hashable, Sendable, Identifiable {
    let prompt: Prompt
    let takes: [Take]

    var id: String { prompt.id }

    private enum CodingKeys: String, CodingKey { case takes }

    init(from decoder: Decoder) throws {
        prompt = try Prompt(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        takes = try container.decode([Take].self, forKey: .takes)
    }
}

// MARK: - Take

struct Take: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let promptId: String
    let sessionId: String
    let attempt: Int
    let recordedAt: Date
    let durationS: Double
    let micRoute: MicRoute
    let status: TakeStatus
    let statusChangedAt: Date
    let coachingStatus: CoachingStatus
    let previousTakeId: String?
    let error: TakeError?
    let summary: TakeSummary?
    let createdAt: Date
    let updatedAt: Date
}

struct TakeError: Codable, Hashable, Sendable {
    let code: TakeErrorCode
    let message: String
}

/// Filled once a take is `done`, for lists and history.
struct TakeSummary: Codable, Hashable, Sendable {
    let verdict: String?
    let focusTitles: [String]
    let fillersPer100Words: Double?
    let blocks: Int?
    let restarts: Int?
    let wpmVoiced: Double?

    private enum CodingKeys: String, CodingKey {
        case verdict, focusTitles, fillersPer100Words, blocks, restarts, wpmVoiced
    }

    init(
        verdict: String?, focusTitles: [String], fillersPer100Words: Double?, blocks: Int?,
        restarts: Int?, wpmVoiced: Double?
    ) {
        self.verdict = verdict
        self.focusTitles = focusTitles
        self.fillersPer100Words = fillersPer100Words
        self.blocks = blocks
        self.restarts = restarts
        self.wpmVoiced = wpmVoiced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try container.decodeIfPresent(String.self, forKey: .verdict)
        // "summary.focus_titles are ... empty without coaching": tolerate null as empty too.
        focusTitles = try container.decodeIfPresent([String].self, forKey: .focusTitles) ?? []
        fillersPer100Words = try container.decodeIfPresent(Double.self, forKey: .fillersPer100Words)
        blocks = try container.decodeIfPresent(Int.self, forKey: .blocks)
        restarts = try container.decodeIfPresent(Int.self, forKey: .restarts)
        wpmVoiced = try container.decodeIfPresent(Double.self, forKey: .wpmVoiced)
    }
}

// MARK: - Health, questions, report

struct Health: Codable, Hashable, Sendable {
    let status: String
    let apiVersion: String
    let serverVersion: String
    let sttEngine: String
    let coaching: CoachingInfo
    let queueLength: Int
}

struct CoachingInfo: Codable, Hashable, Sendable {
    let available: Bool
    let model: String?
    let rubricVersion: String?
    let promptVersion: String?
}

struct Question: Codable, Hashable, Sendable {
    let text: String
    let category: PromptCategory
    let targetSeconds: Int
}

struct QuestionsResponse: Codable, Hashable, Sendable {
    let source: QuestionSource
    let questions: [Question]
}

/// `GET /v1/takes/{id}/report`.
struct TakeReport: Decodable, Sendable {
    let take: Take
    let prompt: Prompt
    let analysis: Analysis
    let coaching: CoachingReport?
    let hasComparison: Bool
}

/// The body of every non-2xx response.
struct APIErrorBody: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let code: String
        let message: String
        let details: JSONValue?
    }

    let error: Payload
}

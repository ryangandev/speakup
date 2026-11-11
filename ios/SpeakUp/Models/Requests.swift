import Foundation

// Request bodies. The contract asks for optional values to be present with `null`, never
// omitted (architecture.md#conventions), and synthesized `Encodable` drops nil optionals,
// so each body encodes its optionals explicitly.

/// `PUT /v1/sessions/{id}`.
struct SessionCreateRequest: Encodable, Hashable, Sendable {
    let mode: SessionMode
    let startedAt: Date
    let nervousnessBefore: Int?

    private enum CodingKeys: String, CodingKey { case mode, startedAt, nervousnessBefore }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(nervousnessBefore, forKey: .nervousnessBefore)
    }
}

/// `PATCH /v1/sessions/{id}` as the app uses it: ending a session with its after-rating.
/// Both keys are always sent; a skipped rating is `null`.
struct SessionEndRequest: Encodable, Hashable, Sendable {
    let endedAt: Date
    let nervousnessAfter: Int?

    private enum CodingKeys: String, CodingKey { case endedAt, nervousnessAfter }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(nervousnessAfter, forKey: .nervousnessAfter)
    }
}

/// `PUT /v1/prompts/{id}`.
struct PromptCreateRequest: Encodable, Hashable, Sendable {
    let sessionId: String
    let kind: PromptKind
    let text: String
    let notes: String?
    let category: PromptCategory?
    let targetSeconds: Int
    let questionSource: QuestionSource
    let language: SpeechLanguage
    /// Only for an interest question.
    var theme: String? = nil

    private enum CodingKeys: String, CodingKey {
        case sessionId, kind, text, notes, category, targetSeconds, questionSource, language, theme
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(notes, forKey: .notes)
        try container.encode(category, forKey: .category)
        try container.encode(targetSeconds, forKey: .targetSeconds)
        try container.encode(questionSource, forKey: .questionSource)
        try container.encode(language, forKey: .language)
        try container.encode(theme, forKey: .theme)
    }
}

/// The `metadata` part of `PUT /v1/takes/{id}`.
struct TakeUploadMetadata: Codable, Hashable, Sendable {
    let promptId: String
    let attempt: Int
    let recordedAt: Date
    let durationS: Double
    let audioSha256: String
    let micRoute: MicRoute
}

/// `POST /v1/questions`. Work questions take a category, interest questions a theme; nil
/// means any.
struct QuestionsRequest: Encodable, Hashable, Sendable {
    let count: Int
    var track: QuestionTrack = .work
    let category: PromptCategory?
    var theme: String? = nil
    let exclude: [String]
    var language: SpeechLanguage = .english

    private enum CodingKeys: String, CodingKey { case count, track, category, theme, exclude, language }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(track, forKey: .track)
        try container.encode(category, forKey: .category)
        try container.encode(theme, forKey: .theme)
        try container.encode(exclude, forKey: .exclude)
        try container.encode(language, forKey: .language)
    }
}

/// `POST /v1/themes`.
struct ThemeCreateRequest: Encodable, Hashable, Sendable {
    let name: String
}

/// `PATCH /v1/themes/{id}`.
struct ThemePatchRequest: Encodable, Hashable, Sendable {
    let pinned: Bool
}

/// `POST /v1/takes/{id}/reprocess`.
struct ReprocessRequest: Encodable, Hashable, Sendable {
    let fromStage: ReprocessStage
}

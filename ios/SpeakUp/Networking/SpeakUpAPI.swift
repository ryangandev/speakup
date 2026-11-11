import Foundation

/// The server API (architecture.md#server-api). `HTTPAPIClient` talks to the Mac mini;
/// the debug-only `MockAPI` serves the same shapes from memory.
protocol SpeakUpAPI: Sendable {
    func health() async throws -> Health
    func createSession(id: String, _ body: SessionCreateRequest) async throws -> Session
    func endSession(id: String, _ body: SessionEndRequest) async throws -> Session
    func sessions(before: Date?, limit: Int) async throws -> SessionList
    func session(id: String) async throws -> SessionDetail
    func questions(_ body: QuestionsRequest) async throws -> QuestionsResponse
    func themes() async throws -> InterestThemeList
    func createTheme(_ body: ThemeCreateRequest) async throws -> InterestTheme
    func updateTheme(id: String, _ body: ThemePatchRequest) async throws -> InterestTheme
    func deleteTheme(id: String) async throws
    func createPrompt(id: String, _ body: PromptCreateRequest) async throws -> Prompt
    func prompt(id: String) async throws -> PromptDetail
    func uploadTake(
        id: String, metadata: TakeUploadMetadata, audioFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take
    func take(id: String) async throws -> Take
    func report(takeID: String) async throws -> TakeReport
    func comparison(takeID: String) async throws -> Comparison
    /// Downloads the take's audio and returns a local file the caller may keep.
    func audio(takeID: String) async throws -> URL
    func reprocess(takeID: String, from stage: ReprocessStage) async throws -> Take
}

/// Every way an API call can fail, with the contract's error codes kept intact.
enum APIError: Error, Equatable, Sendable {
    /// No server address or token in Settings.
    case notConfigured
    /// The request never got an HTTP response.
    case transport(code: URLError.Code, message: String)
    /// A non-2xx response; `code` is the contract's error code.
    case server(status: Int, code: String, message: String, details: JSONValue?)
    /// Something on this phone, such as a missing recording; the message says what.
    case local(String)
    /// A 2xx response whose body did not match the contract.
    case decoding(String)

    var code: String? {
        if case .server(_, let code, _, _) = self { return code }
        return nil
    }

    var isUnauthorized: Bool { code == "unauthorized" }

    /// For `404 not_found` on a create: the unknown parent id the body named
    /// (`details.field`, such as `session_id`), or `""` when the server did not say.
    var missingParentField: String? {
        guard case .server(404, "not_found", _, let details) = self else { return nil }
        if case .object(let object) = details, case .string(let field) = object["field"] {
            return field
        }
        return ""
    }

    /// The failure is about the connection or the server as a whole, not one take, so the
    /// next request would fail the same way.
    var affectsEveryRequest: Bool {
        switch self {
        case .notConfigured, .transport: return true
        case .server(_, let code, _, _): return code == "unauthorized"
        case .local, .decoding: return false
        }
    }

    /// The server could not be reached at all, as opposed to answering with an error.
    var isUnreachable: Bool {
        if case .transport = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .notConfigured:
            return "Add the server address and token in Settings."
        case .transport(_, let message):
            return "Can't reach the server. \(message)"
        case .server(_, "unauthorized", _, _):
            return "The server did not accept the token. Check it in Settings."
        case .server(_, _, let message, _):
            return message
        case .local(let message):
            return message
        case .decoding:
            return "The server sent a response this version of the app does not understand."
        }
    }

    static func wrap(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        if let error = error as? URLError {
            return .transport(code: error.code, message: error.localizedDescription)
        }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .transport(code: .unknown, message: error.localizedDescription)
    }
}

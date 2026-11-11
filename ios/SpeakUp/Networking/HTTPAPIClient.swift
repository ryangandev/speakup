import Foundation

/// The real API client: JSON over HTTPS with a bearer token on every request.
struct HTTPAPIClient: SpeakUpAPI {
    let baseURL: URL
    let token: String
    let session: URLSession
    /// Where downloaded take audio is kept.
    let audioCache: URL

    init(
        baseURL: URL, token: String, session: URLSession = .shared,
        audioCache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Audio", directoryHint: .isDirectory)
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.audioCache = audioCache
    }

    // MARK: Endpoints

    func health() async throws -> Health {
        try await send("GET", "health")
    }

    func createSession(id: String, _ body: SessionCreateRequest) async throws -> Session {
        try await send("PUT", "sessions/\(id)", body: body)
    }

    func endSession(id: String, _ body: SessionEndRequest) async throws -> Session {
        try await send("PATCH", "sessions/\(id)", body: body)
    }

    func sessions(before: Date?, limit: Int) async throws -> SessionList {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            query.append(URLQueryItem(name: "before", value: JSONCoding.formatDate(before)))
        }
        return try await send("GET", "sessions", query: query)
    }

    func session(id: String) async throws -> SessionDetail {
        try await send("GET", "sessions/\(id)")
    }

    func questions(_ body: QuestionsRequest) async throws -> QuestionsResponse {
        try await send("POST", "questions", body: body)
    }

    func themes() async throws -> InterestThemeList {
        try await send("GET", "themes")
    }

    func createTheme(_ body: ThemeCreateRequest) async throws -> InterestTheme {
        try await send("POST", "themes", body: body)
    }

    func updateTheme(id: String, _ body: ThemePatchRequest) async throws -> InterestTheme {
        try await send("PATCH", "themes/\(id)", body: body)
    }

    func deleteTheme(id: String) async throws {
        let request = makeRequest("DELETE", "themes/\(id)")
        let (data, response) = try await perform { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, response: response)
        }
    }

    func createPrompt(id: String, _ body: PromptCreateRequest) async throws -> Prompt {
        try await send("PUT", "prompts/\(id)", body: body)
    }

    func prompt(id: String) async throws -> PromptDetail {
        try await send("GET", "prompts/\(id)")
    }

    func uploadTake(
        id: String, metadata: TakeUploadMetadata, audioFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take {
        let boundary = "speakup-\(IDs.make())"
        let bodyFile = FileManager.default.temporaryDirectory
            .appending(path: "upload-\(id).multipart")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        do {
            let metadataJSON = try JSONCoding.encoder().encode(metadata)
            try MultipartTakeBody.write(
                metadata: metadataJSON, audioFile: audioFile, boundary: boundary, to: bodyFile)
        } catch {
            throw APIError.transport(
                code: .cannotOpenFile, message: "The recording could not be read from this phone.")
        }
        var request = makeRequest("PUT", "takes/\(id)")
        request.setValue(
            MultipartTakeBody.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, response) = try await perform {
            try await session.upload(for: request, fromFile: bodyFile, delegate: delegate)
        }
        return try decodeResponse(data: data, response: response)
    }

    func take(id: String) async throws -> Take {
        try await send("GET", "takes/\(id)")
    }

    func report(takeID: String) async throws -> TakeReport {
        try await send("GET", "takes/\(takeID)/report")
    }

    func comparison(takeID: String) async throws -> Comparison {
        try await send("GET", "takes/\(takeID)/comparison")
    }

    func audio(takeID: String) async throws -> URL {
        let destination = audioCache.appending(path: "\(takeID).wav")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let request = makeRequest("GET", "takes/\(takeID)/audio")
        let (file, response) = try await perform { try await session.download(for: request) }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: file)) ?? Data()
            throw Self.error(from: data, response: response)
        }
        try FileManager.default.createDirectory(at: audioCache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    func reprocess(takeID: String, from stage: ReprocessStage) async throws -> Take {
        try await send("POST", "takes/\(takeID)/reprocess", body: ReprocessRequest(fromStage: stage))
    }

    // MARK: Plumbing

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [])
        -> URLRequest
    {
        var url = baseURL.appending(path: "v1/\(path)")
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = makeRequest(method, path, query: query)
        let (data, response) = try await perform { try await session.data(for: request) }
        return try decodeResponse(data: data, response: response)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ method: String, _ path: String, body: Body
    ) async throws -> Response {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONCoding.encoder().encode(body)
        let (data, response) = try await perform { try await session.data(for: request) }
        return try decodeResponse(data: data, response: response)
    }

    /// Runs a URLSession call and turns transport failures into `APIError.transport`.
    private func perform<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as URLError {
            throw APIError.transport(code: error.code, message: error.localizedDescription)
        }
    }

    private func decodeResponse<Response: Decodable>(data: Data, response: URLResponse) throws
        -> Response
    {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, response: response)
        }
        do {
            return try JSONCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    static func error(from data: Data, response: URLResponse) -> APIError {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let body = try? JSONCoding.decoder().decode(APIErrorBody.self, from: data) {
            return .server(
                status: status, code: body.error.code, message: body.error.message,
                details: body.error.details)
        }
        let message = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return .server(status: status, code: "http_\(status)", message: message, details: nil)
    }
}

/// Reports upload progress from one upload task.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

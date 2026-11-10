import Foundation
import Testing
@testable import SpeakUp

/// The HTTP client against a stub `URLProtocol` serving the contract's examples.
@Suite(.serialized)
struct APIClientTests {
    let base = URL(string: "https://mac-mini.example-tailnet.ts.net")!
    let token = "test-token-not-a-secret"

    private func client() -> HTTPAPIClient {
        HTTPAPIClient(
            baseURL: base, token: token, session: StubURLProtocol.session(),
            audioCache: FileManager.default.temporaryDirectory.appending(path: "AudioCache-\(UUID().uuidString)"))
    }

    private func lastRequest() throws -> StubURLProtocol.Recorded {
        try #require(StubURLProtocol.requests.last)
    }

    @Test func healthSendsBearerTokenAndDecodes() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("health")) }
        let health = try await client().health()
        #expect(health.coaching.available)
        let request = try lastRequest().request
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://mac-mini.example-tailnet.ts.net/v1/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test func createSessionPutsTheContractBody() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(201, Fixture.data("session")) }
        let id = "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10"
        let body = SessionCreateRequest(
            mode: .home, startedAt: try #require(JSONCoding.parseDate("2026-11-09T08:12:03.115Z")),
            nervousnessBefore: 3)
        let session = try await client().createSession(id: id, body)
        #expect(session.id == id)
        let recorded = try lastRequest()
        #expect(recorded.request.httpMethod == "PUT")
        #expect(recorded.request.url?.path() == "/v1/sessions/\(id)")
        #expect(recorded.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(Fixture.sameJSON(try #require(recorded.body), Fixture.data("session_create_request")))
    }

    /// A repeated create answers 200 with the same resource; the client treats it like 201.
    @Test func repeatedCreateIsHarmless() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("session")) }
        let body = SessionCreateRequest(mode: .home, startedAt: Date(), nervousnessBefore: nil)
        let session = try await client().createSession(id: "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", body)
        #expect(session.mode == .home)
    }

    @Test func endSessionPatches() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("session")) }
        let body = SessionEndRequest(
            endedAt: try #require(JSONCoding.parseDate("2026-11-09T08:41:50.020Z")), nervousnessAfter: 2)
        _ = try await client().endSession(id: "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", body)
        let recorded = try lastRequest()
        #expect(recorded.request.httpMethod == "PATCH")
        #expect(Fixture.sameJSON(try #require(recorded.body), Fixture.data("session_end_request")))
    }

    @Test func sessionsPassesPagingQuery() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("sessions_list")) }
        let before = try #require(JSONCoding.parseDate("2026-11-09T08:12:03.115Z"))
        let list = try await client().sessions(before: before, limit: 20)
        #expect(list.sessions.count == 1)
        let url = try #require(try lastRequest().request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.path == "/v1/sessions")
        #expect(query["limit"] == "20")
        #expect(query["before"] == "2026-11-09T08:12:03.115Z")
    }

    @Test func sessionDetailAndPrompt() async throws {
        StubURLProtocol.install { request in
            if request.url?.path().hasPrefix("/v1/prompts/") == true {
                var prompt = Fixture.promptObject()
                prompt["takes"] = [Fixture.object("take_done")]
                return StubURLProtocol.json(200, try JSONSerialization.data(withJSONObject: prompt))
            }
            return StubURLProtocol.json(200, Fixture.data("session_detail"))
        }
        let detail = try await client().session(id: "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10")
        #expect(detail.prompts.count == 1)
        let prompt = try await client().prompt(id: "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8")
        #expect(prompt.takes.first?.status == .done)
    }

    @Test func questionsPostsTheContractBody() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("questions_response")) }
        let response = try await client().questions(
            QuestionsRequest(
                count: 3, category: .decision,
                exclude: ["Why did we choose Postgres over DynamoDB for the billing service?"]))
        #expect(response.questions.count == 3)
        let recorded = try lastRequest()
        #expect(recorded.request.httpMethod == "POST")
        #expect(Fixture.sameJSON(try #require(recorded.body), Fixture.data("questions_request")))
    }

    @Test func createPromptPutsTheContractBody() async throws {
        StubURLProtocol.install { _ in
            StubURLProtocol.json(201, try JSONSerialization.data(withJSONObject: Fixture.promptObject()))
        }
        let body = PromptCreateRequest(
            sessionId: "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", kind: .impromptu,
            text: "Why did we choose Postgres over DynamoDB for the billing service?", notes: nil,
            category: .decision, targetSeconds: 90, questionSource: .claude, language: .english)
        let prompt = try await client().createPrompt(id: "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8", body)
        #expect(prompt.category == .decision)
        let recorded = try lastRequest()
        #expect(recorded.request.httpMethod == "PUT")
        #expect(Fixture.sameJSON(try #require(recorded.body), Fixture.data("prompt_create_request")))
    }

    @Test func uploadTakeIsMultipartPut() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(201, Fixture.data("take_uploaded")) }
        let audio = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: audio, sampleRate: 16_000)
        try writer.append([Int16](repeating: 100, count: 1_600))
        try writer.finish()
        defer { try? FileManager.default.removeItem(at: audio) }
        let metadata = try Fixture.decode(TakeUploadMetadata.self, "take_upload_metadata")

        let take = try await client().uploadTake(
            id: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21", metadata: metadata, audioFile: audio, progress: { _ in })

        #expect(take.status == .uploaded)
        let request = try lastRequest().request
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/v1/takes/e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test func multipartBodyHasMetadataThenAudio() throws {
        let directory = FileManager.default.temporaryDirectory
        let audio = directory.appending(path: "part-\(UUID().uuidString).wav")
        let output = directory.appending(path: "body-\(UUID().uuidString)")
        let audioBytes = Data([1, 2, 3, 4, 5])
        try audioBytes.write(to: audio)
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: output)
        }
        let metadata = Data(#"{"attempt":1}"#.utf8)
        try MultipartTakeBody.write(metadata: metadata, audioFile: audio, boundary: "XYZ", to: output)
        let body = try Data(contentsOf: output)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{\"attempt\":1}\r\n"))
        #expect(text.contains("--XYZ\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"take.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(text.hasSuffix("\r\n--XYZ--\r\n"))
        #expect(body.range(of: audioBytes) != nil)
    }

    @Test func reportAndComparison() async throws {
        StubURLProtocol.install { request in
            if request.url?.path().hasSuffix("/comparison") == true {
                return StubURLProtocol.json(200, Fixture.data("comparison"))
            }
            return StubURLProtocol.json(200, try JSONSerialization.data(withJSONObject: Fixture.fullReportObject()))
        }
        let report = try await client().report(takeID: "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4")
        #expect(report.coaching != nil)
        let comparison = try await client().comparison(takeID: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21")
        #expect(comparison.previousTakeId == "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4")
    }

    @Test func reprocessPostsStage() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(202, Fixture.data("take_uploaded")) }
        _ = try await client().reprocess(takeID: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21", from: .coaching)
        let recorded = try lastRequest()
        #expect(recorded.request.httpMethod == "POST")
        #expect(recorded.request.url?.path() == "/v1/takes/e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21/reprocess")
        #expect(Fixture.sameJSON(try #require(recorded.body), Fixture.data("reprocess_request")))
    }

    @Test func audioDownloadsWithTokenAndCaches() async throws {
        let wav = WAVWriter.header(sampleRate: 16_000, dataBytes: 0)
        StubURLProtocol.install { _ in (200, ["Content-Type": "audio/wav"], wav) }
        let api = client()
        let url = try await api.audio(takeID: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21")
        #expect(try Data(contentsOf: url) == wav)
        #expect(try lastRequest().request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        let count = StubURLProtocol.requests.count
        _ = try await api.audio(takeID: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21")
        #expect(StubURLProtocol.requests.count == count)
    }

    // MARK: Errors

    @Test func errorBodyKeepsCodeMessageAndDetails() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(404, Fixture.data("error")) }
        await #expect(throws: APIError.server(
            status: 404, code: "not_found", message: "No take with id e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21.",
            details: nil)
        ) {
            _ = try await client().take(id: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21")
        }
    }

    @Test(arguments: [
        (400, "bad_request"), (401, "unauthorized"), (404, "no_previous_take"), (409, "conflict"),
        (409, "not_ready"), (409, "invalid_state"), (413, "payload_too_large"),
        (415, "unsupported_media_type"), (422, "validation_failed"), (500, "internal"),
    ])
    func everyContractErrorCodeSurvives(status: Int, code: String) async throws {
        let body = #"{"error": {"code": "\#(code)", "message": "Message for \#(code).", "details": {"status": "analyzing"}}}"#
        StubURLProtocol.install { _ in StubURLProtocol.json(status, Data(body.utf8)) }
        do {
            _ = try await client().take(id: "x")
            Issue.record("Expected an error")
        } catch let error as APIError {
            #expect(error.code == code)
            if case .server(let gotStatus, _, let message, let details) = error {
                #expect(gotStatus == status)
                #expect(message == "Message for \(code).")
                #expect(details?["status"]?.stringValue == "analyzing")
            }
            #expect(error.isUnauthorized == (code == "unauthorized"))
        }
    }

    @Test func unauthorizedMessagePointsToSettings() {
        let error = APIError.server(status: 401, code: "unauthorized", message: "Unauthorized", details: nil)
        #expect(error.userMessage.contains("Settings"))
    }

    @Test func nonJSONErrorFallsBackToStatus() async throws {
        StubURLProtocol.install { _ in (502, ["Content-Type": "text/html"], Data("<html>Bad gateway</html>".utf8)) }
        do {
            _ = try await client().health()
            Issue.record("Expected an error")
        } catch let error as APIError {
            #expect(error.code == "http_502")
        }
    }

    @Test func transportFailureIsUnreachable() async throws {
        StubURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client().health()
            Issue.record("Expected an error")
        } catch let error as APIError {
            #expect(error.isUnreachable)
            guard case .transport(let code, _) = error else { return }
            #expect(code == .cannotConnectToHost)
        }
    }

    @Test func malformedSuccessIsADecodingError() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Data(#"{"status": "ok"}"#.utf8)) }
        do {
            _ = try await client().health()
            Issue.record("Expected an error")
        } catch let error as APIError {
            guard case .decoding = error else {
                Issue.record("Expected a decoding error, got \(error)")
                return
            }
        }
    }

    @Test func baseURLWithPathOrTrailingSlash() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(200, Fixture.data("health")) }
        let api = HTTPAPIClient(
            baseURL: URL(string: "https://host.ts.net/")!, token: token, session: StubURLProtocol.session())
        _ = try await api.health()
        #expect(try lastRequest().request.url?.absoluteString == "https://host.ts.net/v1/health")
    }
}

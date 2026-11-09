import Foundation

/// Serves canned HTTP responses to a `URLSession` and records the requests it saw.
/// Suites that use it run serialized, since the handler is shared.
final class StubURLProtocol: URLProtocol {
    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data?
    }

    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Responds with a fixture's bytes.
    static func json(_ status: Int, _ data: Data) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let handler = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: body))
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

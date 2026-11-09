import Foundation
import Observation
import Security

/// The server token lives in the Keychain, never in UserDefaults or a file.
struct Keychain: Sendable {
    let service: String

    func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String?, for account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Settings the user edits: server address, token, default prepared length, and in debug
/// builds the mock server.
@MainActor
@Observable
final class AppSettings {
    static let preparedLengths = [30, 60, 120, 180, 300]
    static let impromptuLengths = [30, 60, 90, 120, 180, 300]
    static let defaultPreparedSeconds = 120
    static let defaultImpromptuSeconds = 90

    private let defaults: UserDefaults
    private let keychain: Keychain

    private(set) var serverAddress: String
    private(set) var token: String
    var defaultPreparedSeconds: Int {
        didSet { defaults.set(defaultPreparedSeconds, forKey: Keys.preparedSeconds) }
    }

    #if DEBUG
    var useMockServer: Bool {
        didSet { defaults.set(useMockServer, forKey: Keys.useMock) }
    }
    var mockScenario: MockScenario {
        didSet { defaults.set(mockScenario.rawValue, forKey: Keys.mockScenario) }
    }
    #endif

    private enum Keys {
        static let serverAddress = "serverAddress"
        static let preparedSeconds = "defaultPreparedSeconds"
        static let token = "server-token"
        static let useMock = "debug.useMockServer"
        static let mockScenario = "debug.mockScenario"
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: Keychain = Keychain(service: "dev.ryangan.speakup")
    ) {
        self.defaults = defaults
        self.keychain = keychain
        serverAddress = defaults.string(forKey: Keys.serverAddress) ?? ""
        token = keychain.read(Keys.token) ?? ""
        let seconds = defaults.integer(forKey: Keys.preparedSeconds)
        defaultPreparedSeconds = Self.preparedLengths.contains(seconds) ? seconds : Self.defaultPreparedSeconds
        #if DEBUG
        useMockServer = defaults.bool(forKey: Keys.useMock)
        mockScenario = MockScenario(rawValue: defaults.string(forKey: Keys.mockScenario) ?? "") ?? .normal
        #endif
    }

    var serverURL: URL? { Self.validatedURL(serverAddress) }

    var isConfigured: Bool {
        #if DEBUG
        if useMockServer { return true }
        #endif
        return serverURL != nil && !token.isEmpty
    }

    func saveServer(address: String, token newToken: String?) {
        serverAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(serverAddress, forKey: Keys.serverAddress)
        if let newToken {
            let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            keychain.write(trimmed, for: Keys.token)
            token = trimmed
        }
    }

    /// An http or https URL with a host; anything else is rejected.
    static func validatedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }
}

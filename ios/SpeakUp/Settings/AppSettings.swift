import Foundation
import Observation
import Security

/// A token entered in Settings lives in the Keychain, never in UserDefaults or a file.
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

    struct WriteError: Error, Equatable {
        let status: OSStatus

        var message: String {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The token could not be saved in the Keychain: \(reason)"
        }
    }

    /// Saves `value`, or deletes the item for nil or empty. Updates an existing item in
    /// place, so a failed write never leaves the old token deleted.
    func write(_ value: String?, for account: String) throws(WriteError) {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw WriteError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw WriteError(status: update) }
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else { throw WriteError(status: add) }
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
    /// The language Home records in next.
    var language: SpeechLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    /// Whether a take's notes start open on the recording screen; off keeps them behind Show notes.
    var showsNotesWhileRecording: Bool {
        didSet { defaults.set(showsNotesWhileRecording, forKey: Keys.showsNotesWhileRecording) }
    }
    /// Whether Home offers driving mode. It is set aside for now (product.md#driving-mode), so
    /// only the `-showsDriving YES` launch argument turns it on, for its UI tests and device checks.
    let showsDriving: Bool

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
        static let showsDriving = "showsDriving"
        static let showsNotesWhileRecording = "showsNotesWhileRecording"
        static let language = "language"
        static let token = "server-token"
        static let useMock = "debug.useMockServer"
        static let mockScenario = "debug.mockScenario"
    }

    /// `bundled` fills in the address and token that Settings has not saved.
    init(
        defaults: UserDefaults = .standard,
        keychain: Keychain = Keychain(service: "dev.ryangan.speakup"),
        bundled: BundledServer? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        serverAddress = defaults.string(forKey: Keys.serverAddress) ?? bundled?.address ?? ""
        token = keychain.read(Keys.token) ?? bundled?.token ?? ""
        let seconds = defaults.integer(forKey: Keys.preparedSeconds)
        defaultPreparedSeconds = Self.preparedLengths.contains(seconds) ? seconds : Self.defaultPreparedSeconds
        showsDriving = defaults.bool(forKey: Keys.showsDriving)
        showsNotesWhileRecording = defaults.bool(forKey: Keys.showsNotesWhileRecording)
        language = defaults.string(forKey: Keys.language).map(SpeechLanguage.init(rawValue:)) ?? .english
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

    /// Saves the address, and the token when one is given. The token in memory only changes
    /// once the Keychain has it, so the app never runs on a token that is gone after a relaunch.
    func saveServer(address: String, token newToken: String?) throws(Keychain.WriteError) {
        serverAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(serverAddress, forKey: Keys.serverAddress)
        if let newToken {
            let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            try keychain.write(trimmed, for: Keys.token)
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

/// The server this build was made for: `LocalServer.json`, which `ios/scripts/write-local-server.sh`
/// writes from `server/.env` and Tailscale. The file is ignored by git, and Xcode bundles it when
/// it exists, so a fresh install or a new simulator needs no typing in Settings.
struct BundledServer: Decodable, Equatable, Sendable {
    let address: String
    let token: String

    static let fileName = "LocalServer"

    /// The bundle's server, or nil when the build has none or it cannot be read.
    static func load(from bundle: Bundle = .main) -> BundledServer? {
        guard let url = bundle.url(forResource: fileName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BundledServer.self, from: data)
    }
}

import Foundation
import Testing
@testable import SpeakUp

/// The token's Keychain item: replaced in place, and only reported saved when it is.
struct KeychainTests {
    let keychain = Keychain(service: "dev.ryangan.speakup.tests.\(UUID().uuidString)")
    let account = "server-token"

    @Test func writeAddsThenUpdatesInPlaceThenDeletes() throws {
        try keychain.write("first-token", for: account)
        #expect(keychain.read(account) == "first-token")

        try keychain.write("second-token", for: account)
        #expect(keychain.read(account) == "second-token")

        try keychain.write(nil, for: account)
        #expect(keychain.read(account) == nil)
        // Deleting what is not there is not an error.
        try keychain.write("", for: account)
    }

    @MainActor
    @Test func settingsKeepTheTokenOnlyOnceTheKeychainHasIt() throws {
        let defaults = try #require(UserDefaults(suiteName: "keychain-tests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        try settings.saveServer(address: "https://mac-mini.ts.net", token: "a-token-of-thirty-two-characters")
        #expect(settings.token == "a-token-of-thirty-two-characters")
        #expect(AppSettings(defaults: defaults, keychain: keychain).token == "a-token-of-thirty-two-characters")
        try keychain.write(nil, for: account)
    }

    /// The build's server fills in what Settings has not saved, and never replaces what it has.
    @MainActor
    @Test func theBundledServerIsUsedUntilSettingsSavesOne() throws {
        let defaults = try #require(UserDefaults(suiteName: "keychain-tests-\(UUID().uuidString)"))
        let bundled = BundledServer(address: "https://built-in.ts.net", token: "a-bundled-token-of-32-characters")
        let fresh = AppSettings(defaults: defaults, keychain: keychain, bundled: bundled)
        #expect(fresh.serverAddress == "https://built-in.ts.net")
        #expect(fresh.token == "a-bundled-token-of-32-characters")
        #expect(fresh.isConfigured)

        try fresh.saveServer(address: "https://typed.ts.net", token: "a-typed-token-of-thirty-two-chars")
        let later = AppSettings(defaults: defaults, keychain: keychain, bundled: bundled)
        #expect(later.serverAddress == "https://typed.ts.net")
        #expect(later.token == "a-typed-token-of-thirty-two-chars")
        try keychain.write(nil, for: account)
    }
}

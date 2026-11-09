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
}

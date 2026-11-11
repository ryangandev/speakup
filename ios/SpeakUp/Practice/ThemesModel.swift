import Foundation
import Observation

/// Ryan's interest themes (product.md#home): what `GET /v1/themes` last returned, kept in
/// UserDefaults so the chips show at once on launch, and his edits to them.
@MainActor
@Observable
final class ThemesModel {
    static let cacheKey = "interestThemes"

    private(set) var themes: [InterestTheme]
    /// Why the last edit failed; cleared by the next one.
    private(set) var errorMessage: String?
    private(set) var isAdding = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themes = defaults.data(forKey: Self.cacheKey).flatMap {
            try? JSONCoding.decoder().decode(InterestThemeList.self, from: $0).themes
        } ?? []
    }

    var names: [String] { themes.map(\.name) }

    static func removeCache(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: cacheKey)
    }

    /// Takes the server's themes. A failure keeps the cached ones: the chips still work, and
    /// the questions request says whether the server is there.
    func refresh(api: any SpeakUpAPI) async {
        guard let list = try? await api.themes() else { return }
        store(list.themes)
    }

    /// Adds a theme, or brings back one he removed. False when the server refused it.
    @discardableResult
    func add(_ name: String, api: any SpeakUpAPI) async -> Bool {
        let name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return false }
        isAdding = true
        defer { isAdding = false }
        errorMessage = nil
        do {
            _ = try await api.createTheme(ThemeCreateRequest(name: name))
            await refresh(api: api)
            return true
        } catch {
            errorMessage = APIError.wrap(error).userMessage
            return false
        }
    }

    func setPinned(_ theme: InterestTheme, _ pinned: Bool, api: any SpeakUpAPI) async {
        errorMessage = nil
        guard let index = themes.firstIndex(where: { $0.id == theme.id }) else { return }
        var updated = themes
        updated[index].pinned = pinned
        themes = updated
        do {
            _ = try await api.updateTheme(id: theme.id, ThemePatchRequest(pinned: pinned))
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
        // The server orders them: pinned first.
        await refresh(api: api)
    }

    func remove(_ theme: InterestTheme, api: any SpeakUpAPI) async {
        errorMessage = nil
        themes.removeAll { $0.id == theme.id }
        do {
            try await api.deleteTheme(id: theme.id)
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
        await refresh(api: api)
    }

    private func store(_ themes: [InterestTheme]) {
        self.themes = themes
        if let data = try? JSONCoding.encoder().encode(InterestThemeList(themes: themes)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }
}

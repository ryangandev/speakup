import Foundation
import Testing
@testable import SpeakUp

/// Home's topic: questions on interest themes or about work, kept per pick and language.
@MainActor
struct TopicModelTests {
    private func question(_ text: String, theme: String? = "Travel", seconds: Int = 60) -> Question {
        Question(text: text, category: theme == nil ? .decision : .interest, theme: theme, targetSeconds: seconds)
    }

    /// An API that answers every questions request with one question naming the request.
    private func api(record: @escaping @Sendable (QuestionsRequest) -> Void = { _ in }) -> FakeAPI {
        let api = FakeAPI()
        let counter = Counter()
        api.onQuestions = { request in
            record(request)
            let n = counter.next()
            let name = "\(request.track.rawValue) \(request.theme ?? request.category?.rawValue ?? "any") \(request.language.rawValue) \(n)"
            return QuestionsResponse(
                source: .claude,
                questions: [
                    Question(
                        text: name, category: request.track == .interests ? .interest : (request.category ?? .status),
                        theme: request.track == .interests ? (request.theme ?? "Happiness") : nil, targetSeconds: 120)
                ])
        }
        return api
    }

    private func settle(_ model: TopicModel) async {
        for _ in 0..<200 where model.isLoading { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func startsOnTheSavedTrackAndAsksInTheHomeLanguage() async throws {
        let requests = Recorder<QuestionsRequest>()
        let api = api { requests.append($0) }
        let model = TopicModel()
        model.start(track: .interests, language: .chinese, api: api)
        await settle(model)
        #expect(model.choice == .question(.interest(nil)))
        let request = try #require(requests.values.first)
        #expect(request.track == .interests)
        #expect(request.category == nil)
        #expect(request.theme == nil)
        #expect(request.language == .chinese)
        #expect(model.current?.text == "interests any zh 1")
        #expect(model.targetSeconds == 120)
    }

    @Test func eachPickKeepsItsOwnQuestion() async throws {
        let requests = Recorder<QuestionsRequest>()
        let api = api { requests.append($0) }
        let model = TopicModel()
        model.start(track: .interests, language: .english, api: api)
        await settle(model)
        model.select(.question(.interest("Travel")), api: api, ownSeconds: 120)
        await settle(model)
        #expect(model.current?.text == "interests Travel en 2")

        model.select(.question(model.pick(for: .work)), api: api, ownSeconds: 120)
        await settle(model)
        #expect(model.track == .work)
        #expect(model.current?.text == "work any en 3")
        #expect(requests.values.last?.theme == nil)

        // Back on Interests: the Travel chip and its question, with no new request.
        model.select(.question(model.pick(for: .interests)), api: api, ownSeconds: 120)
        #expect(model.choice == .question(.interest("Travel")))
        #expect(model.current?.text == "interests Travel en 2")
        #expect(requests.values.count == 3)

        // Another language is another set of questions.
        model.setLanguage(.chinese, api: api)
        await settle(model)
        #expect(model.current?.text == "interests Travel zh 4")
        model.setLanguage(.english, api: api)
        #expect(model.current?.text == "interests Travel en 2")
        #expect(requests.values.count == 4)
    }

    @Test func shownQuestionsAreExcluded() async throws {
        let requests = Recorder<QuestionsRequest>()
        let api = api { requests.append($0) }
        let model = TopicModel()
        model.start(track: .work, language: .english, api: api)
        await settle(model)
        model.next(api: api)
        await settle(model)
        #expect(requests.values.last?.exclude == ["work any en 1"])
        #expect(requests.values.last?.track == .work)
    }

    @Test func comingBackToHomeKeepsTheQuestionAndLength() async throws {
        let requests = Recorder<QuestionsRequest>()
        let api = api { requests.append($0) }
        let model = TopicModel()
        model.start(track: .interests, language: .english, api: api)
        await settle(model)
        model.targetSeconds = 30
        model.start(track: .work, language: .english, api: api)
        #expect(model.choice == .question(.interest(nil)), "The saved track only applies at first")
        #expect(model.targetSeconds == 30)
        #expect(requests.values.count == 1)
    }

    @Test func aRemovedThemeFallsBackToAny() async throws {
        let api = api()
        let model = TopicModel()
        model.start(track: .interests, language: .english, api: api)
        model.select(.question(.interest("Travel")), api: api, ownSeconds: 120)
        await settle(model)
        model.themesChanged(["travel", "Courage"], api: api)
        #expect(model.choice == .question(.interest("Travel")), "Names match in any case")
        model.themesChanged(["Courage"], api: api)
        #expect(model.choice == .question(.interest(nil)))
        await settle(model)
        #expect(model.current?.text.hasPrefix("interests any") == true)
    }

    @Test func anInterestQuestionBecomesAPromptWithItsTheme() async throws {
        let api = api()
        let directory = FileManager.default.temporaryDirectory.appending(path: "TopicModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PracticeStore(directory: directory)
        let model = TopicModel()
        model.start(track: .interests, language: .chinese, api: api)
        model.select(.question(.interest("Travel")), api: api, ownSeconds: 120)
        await settle(model)
        let prompt = try #require(model.makePrompt(store: store, language: .chinese))
        #expect(prompt.kind == .impromptu)
        #expect(prompt.category == .interest)
        #expect(prompt.theme == "Travel")
        #expect(prompt.language == .chinese)
        #expect(prompt.questionSource == .claude)
        #expect(prompt.createRequest.theme == "Travel")

        model.select(.question(.work(.decision)), api: api, ownSeconds: 120)
        await settle(model)
        let work = try #require(model.makePrompt(store: store, language: .chinese))
        #expect(work.category == .decision)
        #expect(work.theme == nil)
    }
}

/// Interest themes: cached for the next launch, edited through the server.
@MainActor
struct ThemesModelTests {
    private func defaults() -> UserDefaults {
        let name = "themes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func refreshCachesTheServerThemes() async throws {
        let defaults = defaults()
        let model = ThemesModel(defaults: defaults)
        #expect(model.themes.isEmpty)
        await model.refresh(api: FakeAPI())
        #expect(model.names == ["Happiness", "Courage", "Charisma"])
        #expect(ThemesModel(defaults: defaults).names == ["Happiness", "Courage", "Charisma"])
    }

    @Test func aFailedRefreshKeepsTheCachedThemes() async throws {
        let defaults = defaults()
        let model = ThemesModel(defaults: defaults)
        await model.refresh(api: FakeAPI())
        let api = FakeAPI()
        api.onThemes = { throw APIError.transport(code: .notConnectedToInternet, message: "Offline.") }
        await model.refresh(api: api)
        #expect(model.names == ["Happiness", "Courage", "Charisma"])
        #expect(model.errorMessage == nil)
    }

    @Test func editsGoToTheServerAndReload() async throws {
        let model = ThemesModel(defaults: defaults())
        let api = FakeAPI()
        let list = try Fixture.decode(InterestThemeList.self, "themes_list")
        api.onCreateTheme = { body in InterestTheme(id: "new", name: body.name, source: .added, pinned: false) }
        api.onUpdateTheme = { id, body in
            var theme = list.themes.first { $0.id == id }!
            theme.pinned = body.pinned
            return theme
        }
        api.onDeleteTheme = { _ in }
        await model.refresh(api: api)

        #expect(await model.add("  Deep   work ", api: api))
        #expect(api.calls.contains("createTheme Deep work"))
        let charisma = list.themes[2]
        await model.setPinned(charisma, true, api: api)
        #expect(api.calls.contains("updateTheme \(charisma.id) true"))
        await model.remove(charisma, api: api)
        #expect(api.calls.contains("deleteTheme \(charisma.id)"))
        #expect(api.calls.filter { $0 == "themes" }.count == 4)
        #expect(model.errorMessage == nil)
    }

    @Test func aRefusedEditSaysWhy() async throws {
        let model = ThemesModel(defaults: defaults())
        let api = FakeAPI()
        api.onCreateTheme = { _ in
            throw APIError.server(
                status: 422, code: "validation_failed", message: "A theme name is 1 to 40 characters.", details: nil)
        }
        #expect(await model.add(String(repeating: "a", count: 41), api: api) == false)
        #expect(model.errorMessage != nil)
        #expect(await model.add("   ", api: api) == false)
        #expect(api.calls.filter { $0.hasPrefix("createTheme") }.count == 1)
    }
}

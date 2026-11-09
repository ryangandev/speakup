import Foundation
import os

/// Impromptu questions for a drive (plan section 6), so a drive has prompts with no network.
///
/// At drive start, while online, `prefetch()` asks the server for a batch (`POST /v1/questions`,
/// the endpoint home mode uses) and keeps it in a small file next to `practice.json`, so a drive
/// that starts offline still gets the server's questions. With no cached question left it falls
/// back to a built-in bank. Prompts in the car are impromptu only.
///
/// A question is never asked twice in one drive, and recently asked questions are sent as
/// `exclude` so the server does not hand them back. The category rotates where it can.
@MainActor
final class DriveQuestions {
    /// One question, and where it came from (`question_source` of the prompt made from it).
    struct Item: Codable, Hashable, Sendable {
        let text: String
        let category: PromptCategory
        let targetSeconds: Int
        let source: QuestionSource
    }

    /// How many questions a prefetch tops the cache up to (the endpoint's maximum).
    static let batchSize = 10
    /// How many asked questions are remembered and sent as `exclude`.
    static let recentLimit = 50

    private(set) var cached: [Item] = []
    private var recent: [String] = []
    private var askedThisDrive: Set<String> = []
    private var lastCategory: PromptCategory?
    private var prefetching: Task<Void, Never>?

    private let fileURL: URL?
    private let api: () -> any SpeakUpAPI
    private let bank: [Item]

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "DriveQuestions")

    /// `fileURL` keeps the cache across launches; nil keeps it in memory only.
    init(fileURL: URL?, api: @escaping () -> any SpeakUpAPI, bank: [Item] = DriveQuestions.bank) {
        self.fileURL = fileURL
        self.api = api
        self.bank = bank
        load()
    }

    /// Where a store's drive questions live: next to its `practice.json`.
    static func fileURL(in store: PracticeStore) -> URL {
        store.directory.appending(path: "drive-questions.json")
    }

    /// Starts a drive: nothing is asked yet.
    func beginDrive() {
        askedThisDrive = []
        lastCategory = nil
    }

    /// Tops the cache up from the server. A failure keeps what is cached; the drive goes on
    /// with it or the bank. Concurrent calls share one request.
    func prefetch() async {
        if let prefetching { return await prefetching.value }
        let missing = Self.batchSize - cached.count
        guard missing > 0 else { return }
        let request = QuestionsRequest(
            count: missing, category: nil, exclude: Array((recent + cached.map(\.text)).suffix(Self.recentLimit)))
        let api = api()
        let task = Task { @MainActor [weak self] in
            do {
                let response = try await api.questions(request)
                self?.add(response)
            } catch {
                Self.log.info("Questions not prefetched: \(APIError.wrap(error).userMessage, privacy: .public)")
            }
        }
        prefetching = task
        await task.value
        prefetching = nil
    }

    /// The next question: a cached one, else one from the bank. Nil when every question has
    /// been asked in this drive.
    func next() -> Item? {
        let fresh = cached.filter { !askedThisDrive.contains($0.text) }
        if let item = Self.pick(from: fresh, after: lastCategory) {
            cached.removeAll { $0.text == item.text }
            asked(item)
            return item
        }
        // Never asked first, then the least recently asked.
        let unasked = bank.enumerated()
            .filter { !askedThisDrive.contains($0.element.text) }
            .sorted { (age(of: $0.element), $0.offset) < (age(of: $1.element), $1.offset) }
            .map(\.element)
        guard let item = Self.pick(from: unasked, after: lastCategory) else { return nil }
        asked(item)
        return item
    }

    /// Where `item` is in the recently asked list: -1 when never asked, 0 for the oldest.
    private func age(of item: Item) -> Int {
        recent.firstIndex(of: item.text) ?? -1
    }

    /// The first item whose category differs from the last one asked, else the first.
    private static func pick(from items: [Item], after category: PromptCategory?) -> Item? {
        items.first { $0.category != category } ?? items.first
    }

    private func asked(_ item: Item) {
        askedThisDrive.insert(item.text)
        lastCategory = item.category
        recent.removeAll { $0 == item.text }
        recent.append(item.text)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        save()
    }

    private func add(_ response: QuestionsResponse) {
        let known = Set(cached.map(\.text) + recent)
        for question in response.questions where !known.contains(question.text) {
            cached.append(
                Item(
                    text: question.text, category: question.category, targetSeconds: question.targetSeconds,
                    source: response.source))
        }
        save()
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var cached: [Item]
        var recent: [String]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let saved = try JSONCoding.decoder().decode(Saved.self, from: data)
            cached = saved.cached
            recent = saved.recent
        } catch {
            // Only a cache: start empty and let the next prefetch refill it.
            Self.log.error("drive-questions.json did not decode: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONCoding.encoder().encode(Saved(cached: cached, recent: recent))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Could not save drive questions: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Built-in bank

    /// A subset of the server's bank (`server/src/speakup/coaching/resources/question-bank.json`),
    /// four per category, for a drive with no cached question.
    static let bank: [Item] = bankRows.map {
        Item(text: $0.text, category: PromptCategory(rawValue: $0.category), targetSeconds: $0.seconds, source: .bank)
    }

    private static let bankRows: [(category: String, seconds: Int, text: String)] = [
        ("decision", 90, "Why did your team pick a relational database over a NoSQL store for your last new service?"),
        ("status", 90, "Your manager asks why your project slipped two weeks. Explain what happened and what you are doing about it."),
        ("explain", 120, "Explain how your team's deployment pipeline works to a new teammate on their first day."),
        ("pushback", 60, "A product manager wants a feature by Friday that you think needs two weeks. Push back."),
        ("other", 90, "Introduce yourself and your role at the start of a meeting with a new team."),
        ("decision", 90, "You chose to rewrite a module instead of refactoring it in place. Walk your manager through why."),
        ("status", 90, "Give today's stand-up update: what you finished yesterday, what you are doing today, and what is blocking you."),
        ("explain", 120, "A product manager asks what technical debt is and why it slows the team down. Explain it."),
        ("pushback", 60, "Your manager asks you to skip writing tests to hit a deadline. Push back."),
        ("other", 90, "Summarize the decisions from a long design meeting for people who missed it."),
        ("decision", 90, "Why did you build this feature yourselves instead of using a third-party library or service?"),
        ("status", 90, "A migration you own is halfway done. Give a status update to the teams who depend on it."),
        ("explain", 120, "Explain what an API is to someone in sales who keeps hearing the word."),
        ("pushback", 60, "A senior engineer proposes a design you think is too complex for the problem. Push back in the review."),
        ("other", 90, "Give a teammate feedback on a pull request that works but is hard to read."),
        ("decision", 90, "A new teammate asks why the team uses a monorepo. Explain the reasoning."),
        ("status", 90, "You are blocked waiting on another team. Explain the situation to your manager and what you need."),
        ("explain", 120, "Explain the system you work on most to a designer who just joined the team."),
        ("pushback", 60, "Another team asks you to take on their on-call duty for a month. Decline and offer an alternative."),
        ("other", 90, "Ask your manager for time to work on a project you care about. Make the case."),
    ]
}

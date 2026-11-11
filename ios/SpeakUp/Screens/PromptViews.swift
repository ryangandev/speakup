import SwiftUI

/// The topic on Home (product.md#home): a question, on one of Ryan's interest themes or about
/// work, or a topic of his own.
struct TopicPicker: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TopicModel
    var focusedField: FocusState<TopicModel.Field?>.Binding
    @State private var isEditingThemes = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack {
                FieldLabel("Language")
                Spacer()
                Picker("Language", selection: language) {
                    ForEach(SpeechLanguage.choices, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Picker("Topic", selection: source) {
                Text("Question").tag(TopicModel.Source.question)
                Text("Your own").tag(TopicModel.Source.own)
            }
            .pickerStyle(.segmented)

            switch model.choice {
            case .question(let pick):
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Picker("Questions", selection: track) {
                        Text("Interests").tag(QuestionTrack.interests)
                        Text("Work").tag(QuestionTrack.work)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    chips(for: pick)
                }
                questionArea(pick)
            case .own:
                ownTopic
            }

            if model.canPickLength {
                LengthPicker(options: AppSettings.impromptuLengths, selection: $model.targetSeconds)
            }
        }
        .sheet(isPresented: $isEditingThemes) {
            ThemesSheet()
        }
        .onChange(of: app.themes.names) { _, names in
            model.themesChanged(names, api: app.api)
        }
    }

    private var language: Binding<SpeechLanguage> {
        Binding(
            get: { app.settings.language },
            set: {
                app.settings.language = $0
                model.setLanguage($0, api: app.api)
            })
    }

    private var source: Binding<TopicModel.Source> {
        Binding(
            get: { model.choice == .own ? .own : .question },
            set: { select($0 == .own ? .own : .question(model.pick(for: model.track))) })
    }

    private var track: Binding<QuestionTrack> {
        Binding(
            get: { model.track },
            set: {
                app.settings.questionTrack = $0
                select(.question(model.pick(for: $0)))
            })
    }

    private func select(_ choice: TopicModel.Choice) {
        model.select(choice, api: app.api, ownSeconds: app.settings.defaultPreparedSeconds)
    }

    @ViewBuilder private func chips(for pick: TopicModel.Pick) -> some View {
        FlowLayout(spacing: Theme.Spacing.s, lineSpacing: Theme.Spacing.s) {
            switch pick {
            case .interest:
                Chip(title: "Any", isSelected: pick == .interest(nil)) { select(.question(.interest(nil))) }
                    .accessibilityIdentifier("theme.any")
                ForEach(app.themes.themes) { theme in
                    Chip(title: theme.name, isSelected: pick == .interest(theme.name)) {
                        select(.question(.interest(theme.name)))
                    }
                    .accessibilityIdentifier("theme.\(theme.name.lowercased())")
                }
                Chip(title: "Edit", isSelected: false, systemImage: "pencil") { isEditingThemes = true }
                    .accessibilityLabel("Edit themes")
                    .accessibilityIdentifier("themes.edit")
            case .work:
                ForEach(TopicModel.categories, id: \.title) { option in
                    Chip(title: option.title, isSelected: pick == .work(option.category)) {
                        select(.question(.work(option.category)))
                    }
                    .accessibilityIdentifier("topic.\(option.title.lowercased())")
                }
            }
        }
    }

    @ViewBuilder private func questionArea(_ pick: TopicModel.Pick) -> some View {
        if let question = model.current {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let label = Self.label(question, pick: pick) {
                    Text(label.uppercased())
                        .font(Theme.Fonts.captionEmphasis)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Text(question.text)
                    .font(Theme.Fonts.question)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if model.source == .bank {
                    Label("From the built-in question bank, not Claude.", systemImage: "tray.full")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Button {
                    model.next(api: app.api)
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        if model.isLoading { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text("Another question")
                    }
                    .font(Theme.Fonts.bodyEmphasis)
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.errorMessage {
            Banner(
                tone: .error, systemImage: "wifi.exclamationmark",
                message: "\(error) Questions come from the server; you can still write your own topic.",
                actionTitle: "Retry", isWorking: model.isLoading
            ) {
                model.load(api: app.api)
            }
        } else {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                Text("Getting questions").font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    /// What the question is under, when the chip does not already say: its theme or category
    /// for Any.
    private static func label(_ question: Question, pick: TopicModel.Pick) -> String? {
        switch pick {
        case .interest(nil): return question.theme ?? question.category.label
        case .work(nil): return question.category.label
        default: return nil
        }
    }

    private var ownTopic: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                FieldLabel("Topic")
                TextField(app.settings.language == .chinese ? "今天的站会" : "Today's stand-up", text: $model.ownTitle)
                    .font(Theme.Fonts.body)
                    .submitLabel(.next)
                    .focused(focusedField, equals: .title)
                    .onSubmit { focusedField.wrappedValue = .notes }
                    .padding(Theme.Spacing.m)
                    .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .accessibilityIdentifier("topic.ownTitle")
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                FieldLabel("Notes")
                TextEditor(text: $model.ownNotes)
                    .font(Theme.Fonts.body)
                    .focused(focusedField, equals: .notes)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(Theme.Spacing.s)
                    .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .accessibilityLabel("Notes")
                Toggle("Show notes while recording", isOn: showsNotesWhileRecording)
                    .font(Theme.Fonts.secondary)
                    .tint(Theme.Colors.accent)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private var showsNotesWhileRecording: Binding<Bool> {
        Binding(
            get: { app.settings.showsNotesWhileRecording },
            set: { app.settings.showsNotesWhileRecording = $0 })
    }
}

/// The topic Home records next: questions fetched three at a time for the chosen theme or
/// category in the Home language, or a topic Ryan types. Each pick keeps its own questions, so
/// going back to one shows the question it showed before.
@MainActor
@Observable
final class TopicModel {
    /// Which questions: on an interest theme or of a work category, nil for any.
    enum Pick: Hashable {
        case interest(String?)
        case work(PromptCategory?)

        var track: QuestionTrack {
            switch self {
            case .interest: return .interests
            case .work: return .work
            }
        }
    }

    enum Choice: Hashable {
        case question(Pick)
        case own
    }

    enum Source: Hashable { case question, own }

    enum Field: Hashable { case title, notes }

    static let categories: [(title: String, category: PromptCategory?)] = [
        ("Any", nil), ("Decision", .decision), ("Status", .status), ("Explain", .explain), ("Push back", .pushback),
    ]

    private struct Key: Hashable {
        let pick: Pick
        let language: SpeechLanguage
    }

    private struct Batch {
        var queue: [Question]
        let source: QuestionSource
    }

    private(set) var choice: Choice
    /// The track the question page shows, kept while Ryan writes his own topic.
    private(set) var track: QuestionTrack
    private(set) var language: SpeechLanguage = .english
    var ownTitle = ""
    var ownNotes = ""
    var targetSeconds = AppSettings.defaultImpromptuSeconds
    /// The last pick on each track.
    private var interestTheme: String?
    private var workCategory: PromptCategory?
    private var batches: [Key: Batch] = [:]
    private var errors: [Key: String] = [:]
    private var loads: [Key: Task<Void, Never>] = [:]
    /// Questions already shown, sent as `exclude` so the server does not repeat them.
    private var shown: [String] = []
    private var hasStarted = false

    init(track: QuestionTrack = .interests) {
        self.track = track
        choice = .question(track == .work ? .work(nil) : .interest(nil))
    }

    private var key: Key? {
        guard case .question(let pick) = choice else { return nil }
        return Key(pick: pick, language: language)
    }

    var current: Question? { key.flatMap { batches[$0]?.queue.first } }
    var source: QuestionSource { key.flatMap { batches[$0]?.source } ?? .claude }
    var isLoading: Bool { key.map { loads[$0] != nil } ?? false }
    var errorMessage: String? { key.flatMap { errors[$0] } }

    private var trimmedTitle: String { ownTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canPickLength: Bool {
        switch choice {
        case .question: return current != nil
        case .own: return true
        }
    }

    var canRecord: Bool {
        switch choice {
        case .question: return current != nil
        case .own: return !trimmedTitle.isEmpty
        }
    }

    /// The pick the track's page shows: the last one chosen on it.
    func pick(for track: QuestionTrack) -> Pick {
        track == .work ? .work(workCategory) : .interest(interestTheme)
    }

    /// When Home appears or the server changes: the saved track the first time, then a
    /// question for the current pick unless it has one.
    func start(track: QuestionTrack, language: SpeechLanguage, api: any SpeakUpAPI) {
        self.language = language
        if !hasStarted {
            hasStarted = true
            self.track = track
            if case .question = choice { choice = .question(pick(for: track)) }
        }
        // Coming back to Home keeps the question on screen and the length Ryan chose for it.
        guard let key, current == nil, loads[key] == nil else { return }
        load(api: api)
    }

    func setLanguage(_ language: SpeechLanguage, api: any SpeakUpAPI) {
        guard language != self.language else { return }
        self.language = language
        showOrLoad(api: api)
    }

    func select(_ choice: Choice, api: any SpeakUpAPI, ownSeconds: Int) {
        guard choice != self.choice else {
            if current == nil, !isLoading { load(api: api) }
            return
        }
        self.choice = choice
        switch choice {
        case .question(let pick):
            track = pick.track
            switch pick {
            case .interest(let theme): interestTheme = theme
            case .work(let category): workCategory = category
            }
            showOrLoad(api: api)
        case .own:
            targetSeconds = ownSeconds
        }
    }

    /// After the themes change: a removed theme's chip is gone, so its page falls back to Any.
    func themesChanged(_ names: [String], api: any SpeakUpAPI) {
        guard let theme = interestTheme, !names.contains(where: { $0.caseInsensitiveCompare(theme) == .orderedSame })
        else { return }
        interestTheme = nil
        if choice == .question(.interest(theme)) {
            choice = .question(.interest(nil))
            showOrLoad(api: api)
        }
    }

    func next(api: any SpeakUpAPI) {
        guard let key else { return }
        if batches[key]?.queue.isEmpty == false { batches[key]?.queue.removeFirst() }
        if let question = current {
            show(question)
        } else {
            load(api: api)
        }
    }

    func load(api: any SpeakUpAPI) {
        guard let key else { return }
        loads[key]?.cancel()
        errors[key] = nil
        let exclude = Array(shown.suffix(50))
        let request: QuestionsRequest
        switch key.pick {
        case .interest(let theme):
            request = QuestionsRequest(
                count: 3, track: .interests, category: nil, theme: theme, exclude: exclude, language: key.language)
        case .work(let category):
            request = QuestionsRequest(
                count: 3, track: .work, category: category, theme: nil, exclude: exclude, language: key.language)
        }
        loads[key] = Task {
            do {
                let response = try await api.questions(request)
                guard !Task.isCancelled else { return }
                batches[key] = Batch(queue: response.questions, source: response.source)
                if response.questions.isEmpty { errors[key] = "The server sent no questions." }
                if self.key == key, let question = current { show(question) }
            } catch {
                guard !Task.isCancelled else { return }
                errors[key] = APIError.wrap(error).userMessage
            }
            loads[key] = nil
        }
    }

    /// Adds the chosen topic as a prompt of the open home session, opening one when none is.
    func makePrompt(store: PracticeStore, language: SpeechLanguage) -> LocalPrompt? {
        let sessionID = store.openHomeSession?.id ?? store.openNewSession(nervousnessBefore: nil).id
        switch choice {
        case .question:
            guard let question = current else { return nil }
            return store.addPrompt(
                sessionID: sessionID, kind: .impromptu, text: question.text, notes: nil,
                category: question.category, targetSeconds: targetSeconds, questionSource: source,
                language: language, theme: question.theme)
        case .own:
            guard !trimmedTitle.isEmpty else { return nil }
            let notes = ownNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            return store.addPrompt(
                sessionID: sessionID, kind: .prepared, text: trimmedTitle, notes: notes.isEmpty ? nil : notes,
                category: nil, targetSeconds: targetSeconds, questionSource: .typed, language: language)
        }
    }

    /// After a take starts: the next question is ready for the next take, and a typed topic
    /// is cleared.
    func recorded(api: any SpeakUpAPI) {
        switch choice {
        case .question: next(api: api)
        case .own:
            ownTitle = ""
            ownNotes = ""
        }
    }

    /// Shows the current pick's question, or fetches some when it has none and none are coming.
    private func showOrLoad(api: any SpeakUpAPI) {
        guard let key else { return }
        if let question = current {
            show(question)
        } else if loads[key] == nil {
            load(api: api)
        }
    }

    private func show(_ question: Question) {
        if !shown.contains(question.text) { shown.append(question.text) }
        targetSeconds = Self.suggestedSeconds(question)
    }

    /// The question's suggested length, or the nearest one the picker offers.
    private static func suggestedSeconds(_ question: Question) -> Int {
        let suggested = question.targetSeconds
        return AppSettings.impromptuLengths.contains(suggested)
            ? suggested
            : AppSettings.impromptuLengths.min { abs($0 - suggested) < abs($1 - suggested) }
                ?? AppSettings.defaultImpromptuSeconds
    }
}

/// Picks a target length. The take is never cut off at it.
struct LengthPicker: View {
    let options: [Int]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldLabel("Target length")
            // Chips wrap onto a second line rather than truncate, at any text size.
            FlowLayout(spacing: Theme.Spacing.s, lineSpacing: Theme.Spacing.s) {
                ForEach(options, id: \.self) { seconds in
                    Chip(title: Format.target(seconds), isSelected: selection == seconds) { selection = seconds }
                        .accessibilityLabel("Target length \(Format.target(seconds))")
                }
            }
        }
    }
}

struct FieldLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.Colors.textPrimary)
    }
}

/// The pinned area at the bottom of a screen that holds its main actions. A screen whose
/// content never runs under the bar can leave out its material and stay one colour.
struct BottomBar<Content: View>: View {
    var hasMaterial = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Spacing.s) { content }
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.s)
            .background(hasMaterial ? AnyShapeStyle(Theme.barMaterial) : AnyShapeStyle(.clear))
    }
}

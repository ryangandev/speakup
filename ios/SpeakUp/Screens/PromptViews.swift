import SwiftUI

/// The topic on Home (product.md#home): a question from the bank, by category, or Ryan's own.
struct TopicPicker: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TopicModel
    var focusedField: FocusState<TopicModel.Field?>.Binding

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
            case .question:
                FlowLayout(spacing: Theme.Spacing.s, lineSpacing: Theme.Spacing.s) {
                    ForEach(TopicModel.categories, id: \.title) { option in
                        Chip(title: option.title, isSelected: model.choice == .question(option.category)) {
                            select(.question(option.category))
                        }
                        .accessibilityIdentifier("topic.\(option.title.lowercased())")
                    }
                }
                questionArea
            case .own:
                ownTopic
            }

            if model.canPickLength {
                LengthPicker(options: AppSettings.impromptuLengths, selection: $model.targetSeconds)
            }
        }
    }

    private var language: Binding<SpeechLanguage> {
        Binding(get: { app.settings.language }, set: { app.settings.language = $0 })
    }

    private var source: Binding<TopicModel.Source> {
        Binding(
            get: { model.choice == .own ? .own : .question },
            set: { select($0 == .own ? .own : .question(model.questionCategory)) })
    }

    private func select(_ choice: TopicModel.Choice) {
        model.select(choice, api: app.api, ownSeconds: app.settings.defaultPreparedSeconds)
    }

    @ViewBuilder private var questionArea: some View {
        if let question = model.current {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if case .question(nil) = model.choice {
                    Text(question.category.label.uppercased())
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

/// The topic Home records next: questions fetched three at a time for the chosen category,
/// or a topic Ryan types.
@MainActor
@Observable
final class TopicModel {
    enum Choice: Hashable {
        case question(PromptCategory?)
        case own
    }

    enum Source: Hashable { case question, own }

    enum Field: Hashable { case title, notes }

    static let categories: [(title: String, category: PromptCategory?)] = [
        ("Any", nil), ("Decision", .decision), ("Status", .status), ("Explain", .explain), ("Push back", .pushback),
    ]

    private(set) var choice: Choice = .question(nil)
    /// The category of the questions in `queue`, kept while Ryan writes his own topic.
    private(set) var questionCategory: PromptCategory?
    private(set) var queue: [Question] = []
    private(set) var source: QuestionSource = .claude
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var ownTitle = ""
    var ownNotes = ""
    var targetSeconds = AppSettings.defaultImpromptuSeconds
    /// Questions already shown, sent as `exclude` so the server does not repeat them.
    private var shown: [String] = []
    private var loadTask: Task<Void, Never>?

    var current: Question? { queue.first }

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

    func select(_ choice: Choice, api: any SpeakUpAPI, ownSeconds: Int) {
        guard choice != self.choice || (choice != .own && current == nil) else { return }
        self.choice = choice
        switch choice {
        case .question(let category):
            // Back from Your own to the same category: the question shown before is still there.
            if category == questionCategory, let question = current {
                targetSeconds = Self.suggestedSeconds(question)
                return
            }
            questionCategory = category
            queue = []
            load(api: api)
        case .own:
            loadTask?.cancel()
            isLoading = false
            targetSeconds = ownSeconds
        }
    }

    func next(api: any SpeakUpAPI) {
        guard case .question = choice else { return }
        if !queue.isEmpty { queue.removeFirst() }
        if let question = current {
            show(question)
        } else {
            load(api: api)
        }
    }

    func load(api: any SpeakUpAPI) {
        guard case .question(let category) = choice else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let request = QuestionsRequest(count: 3, category: category, exclude: Array(shown.suffix(50)))
        loadTask = Task {
            do {
                let response = try await api.questions(request)
                guard !Task.isCancelled else { return }
                source = response.source
                queue = response.questions
                if let question = current { show(question) }
                if response.questions.isEmpty { errorMessage = "The server sent no questions." }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = APIError.wrap(error).userMessage
            }
            isLoading = false
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
                language: language)
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

    private func show(_ question: Question) {
        shown.append(question.text)
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

import SwiftUI

/// Prepared prompt (product.md#prepared-prompt).
struct PreparedPromptView: View {
    @Environment(AppModel.self) private var app
    @State private var title = ""
    @State private var notes = ""
    @State private var targetSeconds: Int?
    @State private var isStarting = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, notes }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    FieldLabel("Title")
                    TextField("Today's stand-up", text: $title)
                        .font(Theme.Fonts.body)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .title)
                        .onSubmit { focusedField = .notes }
                        .padding(Theme.Spacing.m)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    FieldLabel("Notes", detail: "Optional. Type or dictate the points you want to make.")
                    TextEditor(text: $notes)
                        .font(Theme.Fonts.body)
                        .focused($focusedField, equals: .notes)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .padding(Theme.Spacing.s)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .accessibilityLabel("Notes")
                }
                LengthPicker(
                    options: AppSettings.preparedLengths,
                    selection: Binding(
                        get: { targetSeconds ?? app.settings.defaultPreparedSeconds },
                        set: { targetSeconds = $0 }))
            }
            .screenContent()
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The notes editor takes returns, so the keyboard needs its own way out to reach
            // the length picker underneath. It is in the navigation bar, not a keyboard
            // toolbar: SwiftUI logs "Invalid frame dimension" whenever a keyboard toolbar shows.
            if focusedField != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("hideKeyboard")
                }
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Prepared")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button {
                    record()
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.primary(tint: Theme.Colors.recording))
                .disabled(trimmedTitle.isEmpty || isStarting)
            }
        }
        .onAppear { if title.isEmpty { focusedField = .title } }
    }

    private func record() {
        focusedField = nil
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await MicrophonePermission.request() else {
                app.practice.isMicrophoneDeniedAlertPresented = true
                return
            }
            let sessionID = app.store.openSession?.id ?? app.store.openNewSession(nervousnessBefore: nil).id
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let prompt = app.store.addPrompt(
                    sessionID: sessionID, kind: .prepared, text: trimmedTitle,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes, category: nil,
                    targetSeconds: targetSeconds ?? app.settings.defaultPreparedSeconds,
                    questionSource: .typed)
            else { return }
            await app.practice.record(prompt)
        }
    }
}

/// Impromptu prompt (product.md#impromptu-prompt).
struct ImpromptuPromptView: View {
    @Environment(AppModel.self) private var app
    @State private var model = ImpromptuModel()
    @State private var isStarting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(ImpromptuModel.categories, id: \.title) { option in
                            Chip(title: option.title, isSelected: model.category == option.category) {
                                model.select(category: option.category, api: app.api)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screen)
                }
                .padding(.horizontal, -Theme.Spacing.screen)

                questionArea

                if model.current != nil {
                    LengthPicker(options: AppSettings.impromptuLengths, selection: $model.targetSeconds)
                }
            }
            .screenContent()
        }
        .background(Theme.Colors.background)
        .navigationTitle("Impromptu")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if model.current != nil {
                BottomBar {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Spacing.m) { anotherButton; recordButton }
                        VStack(spacing: Theme.Spacing.s) { recordButton; anotherButton }
                    }
                }
            }
        }
        .task { if model.current == nil { model.load(api: app.api) } }
    }

    @ViewBuilder private var questionArea: some View {
        if let question = model.current {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if model.category == nil {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.errorMessage {
            Banner(
                tone: .error, systemImage: "wifi.exclamationmark",
                message: "\(error) Impromptu practice needs the server.",
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

    private var recordButton: some View {
        Button {
            record()
        } label: {
            Label("Record", systemImage: "mic.fill")
        }
        .buttonStyle(.primary(tint: Theme.Colors.recording))
        .disabled(isStarting)
    }

    private var anotherButton: some View {
        Button {
            model.next(api: app.api)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                if model.isLoading { ProgressView() }
                Text("Another question")
            }
        }
        .buttonStyle(.secondary)
        .disabled(model.isLoading)
    }

    private func record() {
        guard let question = model.current else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await MicrophonePermission.request() else {
                app.practice.isMicrophoneDeniedAlertPresented = true
                return
            }
            let sessionID = app.store.openSession?.id ?? app.store.openNewSession(nervousnessBefore: nil).id
            guard
                let prompt = app.store.addPrompt(
                    sessionID: sessionID, kind: .impromptu, text: question.text, notes: nil,
                    category: question.category, targetSeconds: model.targetSeconds,
                    questionSource: model.source)
            else { return }
            await app.practice.record(prompt)
        }
    }
}

/// Questions fetched three at a time for the chosen category.
@MainActor
@Observable
final class ImpromptuModel {
    static let categories: [(title: String, category: PromptCategory?)] = [
        ("Any", nil), ("Decision", .decision), ("Status", .status), ("Explain", .explain),
        ("Push back", .pushback),
    ]

    private(set) var category: PromptCategory?
    private(set) var queue: [Question] = []
    private(set) var source: QuestionSource = .claude
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var targetSeconds = AppSettings.defaultImpromptuSeconds
    /// Questions already shown, sent as `exclude` so the server does not repeat them.
    private var shown: [String] = []
    private var loadTask: Task<Void, Never>?

    var current: Question? { queue.first }

    func select(category: PromptCategory?, api: any SpeakUpAPI) {
        guard category != self.category || current == nil else { return }
        self.category = category
        queue = []
        load(api: api)
    }

    func next(api: any SpeakUpAPI) {
        if !queue.isEmpty { queue.removeFirst() }
        if let question = current {
            show(question)
        } else {
            load(api: api)
        }
    }

    func load(api: any SpeakUpAPI) {
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

    private func show(_ question: Question) {
        shown.append(question.text)
        let suggested = question.targetSeconds
        targetSeconds = AppSettings.impromptuLengths.contains(suggested)
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
            FieldLabel("Target length", detail: "A guide only; recording never stops at it.")
            // Segments while they fit; a menu at large text sizes, where segments would truncate.
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented).fixedSize()
                picker.pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension LengthPicker {
    fileprivate var picker: some View {
        Picker("Target length", selection: $selection) {
            ForEach(options, id: \.self) { seconds in
                Text(Format.target(seconds)).tag(seconds)
            }
        }
    }
}

struct FieldLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.Colors.textPrimary)
            if let detail {
                Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The pinned area at the bottom of a screen that holds its main actions.
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Spacing.s) { content }
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.s)
            .background(Theme.barMaterial)
    }
}

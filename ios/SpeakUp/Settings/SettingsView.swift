import SwiftUI

/// Settings (product.md#settings), shown as a sheet from Home and first on a fresh install.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    /// A new token being typed; nil keeps the saved one.
    @State private var newToken: String?
    @State private var test: TestState = .idle
    @State private var hasLoaded = false
    #if DEBUG
    @State private var useMock = false
    @State private var scenario = MockScenario.normal
    #endif

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(Health)
        case failed(String)
    }

    private var settings: AppSettings { app.settings }
    private var addressIsValid: Bool { AppSettings.validatedURL(address) != nil }
    private var tokenToUse: String { newToken ?? settings.token }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                testSection
                practiceSection
                #if DEBUG
                debugSection
                #endif
                Section("About") {
                    LabeledContent("App version", value: Self.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
        }
        .onAppear(perform: loadDrafts)
    }

    private var serverSection: some View {
        Section {
            TextField("https://mac-mini.ts.net", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Server address")
            if let newToken {
                SecureField("Token", text: Binding(get: { newToken }, set: { self.newToken = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Token")
            } else {
                HStack {
                    Text(settings.token.isEmpty ? "No token" : String(repeating: "•", count: 12))
                        .foregroundStyle(settings.token.isEmpty ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                        .accessibilityLabel(settings.token.isEmpty ? "No token" : "Token saved")
                    Spacer()
                    Button(settings.token.isEmpty ? "Add token" : "Replace") { newToken = "" }
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if !address.isEmpty && !addressIsValid {
                Text("Enter a full address starting with https://.").foregroundStyle(Theme.Colors.negative)
            } else {
                Text("The Mac mini's Tailscale address. The token is kept in the Keychain.")
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if test == .running { ProgressView() }
                }
            }
            .disabled(test == .running || !canTest)
            switch test {
            case .idle, .running:
                EmptyView()
            case .succeeded(let health):
                Label("The server answered", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.positive)
                LabeledContent("Speech to text", value: health.sttEngine)
                LabeledContent("Coaching", value: health.coaching.available ? "Available" : "Off, no API key")
                LabeledContent("Model", value: health.coaching.model ?? "-")
                LabeledContent("Rubric", value: health.coaching.rubricVersion ?? "-")
                LabeledContent("Server version", value: health.serverVersion)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.Colors.negative)
            }
        }
    }

    private var practiceSection: some View {
        Section("Practice") {
            Picker(
                "Default prepared length",
                selection: Binding(
                    get: { settings.defaultPreparedSeconds }, set: { settings.defaultPreparedSeconds = $0 })
            ) {
                ForEach(AppSettings.preparedLengths, id: \.self) { Text(Format.target($0)).tag($0) }
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Toggle("Mock server", isOn: $useMock)
            if useMock {
                Picker("Scenario", selection: $scenario) {
                    ForEach(MockScenario.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Debug builds only. The mock server answers in memory, so every screen works without the Mac mini.")
        }
    }
    #endif

    private var canTest: Bool {
        #if DEBUG
        if useMock { return true }
        #endif
        return addressIsValid && !tokenToUse.isEmpty
    }

    private func loadDrafts() {
        guard !hasLoaded else { return }
        hasLoaded = true
        address = settings.serverAddress
        newToken = settings.token.isEmpty ? "" : nil
        #if DEBUG
        useMock = settings.useMockServer
        scenario = settings.mockScenario
        #endif
    }

    private func runTest() {
        test = .running
        let api: any SpeakUpAPI
        #if DEBUG
        if useMock {
            MockAPI.shared.scenario = scenario
            api = MockAPI.shared
        } else {
            api = draftClient()
        }
        #else
        api = draftClient()
        #endif
        Task {
            do {
                test = .succeeded(try await api.health())
            } catch {
                test = .failed(APIError.wrap(error).userMessage)
            }
        }
    }

    private func draftClient() -> any SpeakUpAPI {
        guard let url = AppSettings.validatedURL(address) else { return UnconfiguredAPI() }
        return HTTPAPIClient(baseURL: url, token: tokenToUse)
    }

    private func save() {
        let trimmedToken = newToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty replacement keeps the saved token.
        settings.saveServer(address: address, token: trimmedToken.flatMap { $0.isEmpty ? nil : $0 })
        #if DEBUG
        settings.useMockServer = useMock
        settings.mockScenario = scenario
        #endif
        app.settingsChanged()
        dismiss()
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

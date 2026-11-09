import SwiftUI

/// Two tabs, Practice and History; Settings is a sheet; the take flow and a drive cover
/// everything.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        @Bindable var practice = app.practice
        TabView {
            Tab("Practice", systemImage: "mic") {
                PracticeTab()
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistoryTab()
            }
        }
        .tint(Theme.Colors.accent)
        .sheet(isPresented: $app.isSettingsPresented) {
            SettingsView()
        }
        .fullScreenCover(item: $practice.takeFlow) { flow in
            TakeFlowView(flow: flow)
                .environment(app)
                .environment(app.player)
        }
        .fullScreenCover(item: Binding(get: { app.drive }, set: { if $0 == nil { app.closeDrive() } })) { drive in
            DriveView(drive: drive)
                .environment(app)
        }
        .alert("Microphone is off", isPresented: $practice.isMicrophoneDeniedAlertPresented) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("SpeakUp needs the microphone to record a take or start a drive. Turn it on in Settings.")
        }
        .alert(
            "Could not start recording",
            isPresented: Binding(
                get: { practice.recordingError != nil }, set: { if !$0 { practice.recordingError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(practice.recordingError ?? "")
        }
        .alert(
            "Playback",
            isPresented: Binding(
                get: { app.player.errorMessage != nil }, set: { if !$0 { app.player.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.player.errorMessage ?? "")
        }
        .task {
            #if DEBUG
            if DebugLaunch.startsDrive { await app.startDrive() }
            #endif
            await app.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refresh() } }
        }
    }
}

/// The Practice tab's navigation stack.
struct PracticeTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var practice = app.practice
        NavigationStack(path: $practice.path) {
            HomeView()
                .navigationDestination(for: PracticeRoute.self) { route in
                    Group {
                        switch route {
                        case .prepared:
                            PreparedPromptView()
                        case .impromptu:
                            ImpromptuPromptView()
                        case .report(let takeID):
                            ReportView(takeID: takeID, context: .practice)
                        case .comparison(let takeID):
                            ComparisonView(takeID: takeID, context: .practice)
                        }
                    }
                    // Retry replaces the Report at the same depth with the next take's;
                    // the id makes that a new screen rather than the old one's state.
                    .id(route)
                    // Past Home the practice loop has its own pinned actions (Record, Retry,
                    // Next prompt), so the tab bar steps aside to leave room for content.
                    .toolbar(.hidden, for: .tabBar)
                }
        }
    }
}

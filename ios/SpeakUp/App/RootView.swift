import SwiftUI

/// Two tabs, Practice and History; Settings is a sheet; the take flow covers everything.
///
/// A drive replaces the tabs rather than covering them: any sheet that was up when Siri
/// started it leaves with the tabs, so nothing can keep the drive off screen. The selected tab
/// and both navigation paths are kept outside the tabs, so they come back as they were.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = RootTab.practice

    var body: some View {
        @Bindable var app = app
        @Bindable var practice = app.practice
        ZStack {
            if let drive = app.drive {
                DriveView(drive: drive)
                    // A new drive after an ended one is a new screen.
                    .id(ObjectIdentifier(drive))
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            } else {
                TabView(selection: $tab) {
                    Tab("Practice", systemImage: "mic", value: .practice) {
                        PracticeTab()
                    }
                    Tab("History", systemImage: "clock.arrow.circlepath", value: .history) {
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
            }
        }
        .animation(.smooth(duration: 0.35), value: app.isDriving)
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
            if let delay = DebugLaunch.startDriveDelay {
                // A delay leaves time to open a sheet first, as Siri might find one.
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    await app.startDrive()
                }
            }
            #endif
            await app.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refresh() } }
        }
    }
}

enum RootTab: Hashable { case practice, history }

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
                    // New topic), so the tab bar steps aside to leave room for content.
                    .toolbar(.hidden, for: .tabBar)
                }
        }
    }
}

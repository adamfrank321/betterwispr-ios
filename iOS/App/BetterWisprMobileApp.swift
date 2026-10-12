import BetterWisprCore
import SwiftUI

@main
struct BetterWisprMobileApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.model)
                .environment(app.models)
                .environment(app.session)
                .environment(app.sync)
                .preferredColorScheme(app.colorScheme)
                .onOpenURL { _ in app.session.handleKeyboardCommand() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            app.session.handleKeyboardCommand()
            app.model.learnKeyboardCorrections()
            app.sync.schedule(after: .zero)
            app.models.warmUp(app.model.selectedModel)
        }
    }
}

/// Owns the long-lived pieces so views share one of each.
@MainActor @Observable
final class AppState {
    let model: MobileModel
    let models: ModelManager
    let session: DictationSession
    let sync: MobileSync
    let meetings: MeetingRecorderModel

    init() {
        let model = MobileModel()
        let models = ModelManager()
        let meetings = MeetingRecorderModel(model: model, models: models)
        self.model = model
        self.models = models
        self.meetings = meetings
        session = DictationSession(model: model, models: models)
        sync = MobileSync(model: model, activeMeeting: { [weak meetings] in meetings?.activeMeetingID })
    }

    var colorScheme: ColorScheme? {
        switch model.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(MobileModel.self) private var model

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Dictate", systemImage: "mic") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
            MeetingsView()
                .environment(app.meetings)
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
            PersonalizeView()
                .tabItem { Label("Personalize", systemImage: "textformat") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .alert("Library unavailable", isPresented: .constant(model.storageProblem != nil)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.storageProblem ?? "")
        }
    }
}

/// A short confirmation above the tab bar, with Undo when the action can be reversed.
struct ToastView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.subheadline.weight(.semibold))
                    if let message = toast.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let undo = toast.undo {
                    Button("Undo") { undo(); model.toast = nil }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(4))
                if model.toast?.id == toast.id { model.toast = nil }
            }
        }
    }
}

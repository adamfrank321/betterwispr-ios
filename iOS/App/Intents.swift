import AppIntents
import Foundation

/// Starts a dictation from Shortcuts, Siri or the Action Button. The app opens and starts listening;
/// the finished text is copied so it can be pasted anywhere.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate with BetterWispr"
    static let description = IntentDescription("Opens BetterWispr and starts listening. When you stop, the text is copied.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.current?.session.start()
        return .result()
    }
}

struct BetterWisprShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DictateIntent(), phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Dictate", systemImageName: "mic")
    }
}

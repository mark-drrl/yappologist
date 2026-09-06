import SwiftUI

@main
struct echoApp: App {
    @StateObject private var store = TranscriptionStore()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var library = TranscriptLibrary.shared

    init() { DiagnosticLog.startSession() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(themeManager)
                .environmentObject(library)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .tint(themeManager.theme.accent)
                .frame(minWidth: 700, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .tint(themeManager.theme.accent)
        }
    }
}

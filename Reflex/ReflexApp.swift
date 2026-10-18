import SwiftUI
import ReflexCore

@main
struct ReflexApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        #if os(macOS)
        // The app lives in the menu bar. A menu, not a popover, per the HIG
        // (`the-menu-bar.md › Menu bar extras`); settings get their own
        // fixed-settings window through the Settings scene.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
        } label: {
            Image(systemName: "capsule.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
        #else
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        #endif
    }
}

/// Canonical location for converted `.mlpackage` bundles.
///
/// Delegates to `ReflexWhisperKit.defaultModelsDirectory`, which is the single
/// source of truth for "where do the models live". That resolver honors
/// `REFLEX_MODELS` and otherwise derives `Models/` from the repository root via
/// `#filePath`. Keeping one resolver matters: this project has relocated
/// before, and a second hand-rolled copy of the lookup is how the stale
/// `~/Development/Reflex` path survived a move. See Atlas Doctor D17.
///
/// This wrapper adds only the app-specific final fallback: `Models/` bundled
/// inside a shipped `.app` that carries its own weights.
enum ReflexEnvironment {
    static func modelDirectory() -> URL {
        let onDisk = ReflexWhisperKit.defaultModelsDirectory
        if FileManager.default.fileExists(atPath: onDisk.path) {
            return onDisk
        }

        return Bundle.main.resourceURL?
            .appendingPathComponent("Models", isDirectory: true)
            ?? onDisk
    }
}

#if os(macOS)
import SwiftUI
import AppKit
import ReflexCore

/// The menu bar extra's menu: status, the listen toggle, the last thing that
/// happened, and routes into Settings and Quit. A menu, not a popover — the
/// HIG asks for exactly that in `the-menu-bar.md › Menu bar extras`.
struct MenuBarView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Text(statusText)
            .disabled(true)

        if appModel.isListening, !appModel.liveText.isEmpty {
            Text("…\(truncated(appModel.liveText))")
                .disabled(true)
        } else if let result = appModel.lastResult {
            Text(truncated(result.summary))
                .disabled(true)
        }

        Divider()

        Button {
            appModel.toggleListening()
        } label: {
            Label(
                appModel.isListening ? "Stop Listening" : "Start Listening",
                systemImage: appModel.isListening ? "stop.fill" : "mic.fill"
            )
        }
        .disabled(!appModel.loadState.isReady && !appModel.isListening)

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Quit Reflex") {
            NSApp.terminate(nil)
        }
    }

    private var statusText: String {
        if case .loading(let kind) = appModel.loadState { return "Loading \(kind.displayName)…" }
        if case .failed(let reason) = appModel.loadState { return "Unavailable: \(reason)" }
        return appModel.modelStatus
    }

    private func truncated(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}
#endif

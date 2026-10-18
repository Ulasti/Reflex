#if os(macOS)
import SwiftUI
import AppKit
import ReflexCore

/// The Settings scene: general toggles, model choice, input, the notch pill,
/// diagnostics and session logs. This window is the app's whole settings
/// surface now — the old main window is gone and the menu bar extra carries
/// status and the listen toggle.
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var report: SystemDiagnostics.Report?
    @State private var showHistory = false
    @State private var exportDocument: MarkdownDocument?
    @State private var exportFilename = "reflex-sessions.md"
    @State private var exporterShown = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Force English", isOn: $appModel.forcedEnglish)
                Toggle("Verbose session log", isOn: $appModel.verboseLogging)
                Toggle("Feedback sounds", isOn: $appModel.shouldPlayFeedbackSounds)
                Toggle("Suppress while media is playing", isOn: $appModel.suppressWhileMediaPlaying)
            }

            Section("Model") {
                Picker("Model", selection: $appModel.activeModel) {
                    ForEach(ReflexModelKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(appModel.isBusy)
                .onChange(of: appModel.activeModel) { _, kind in
                    appModel.modelSelectionChanged(kind)
                }

                LabeledContent("Status", value: appModel.modelStatus)

                if case .failed(let message) = appModel.loadState {
                    HStack(spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Button("Retry") {
                            Task { await appModel.loadModel(appModel.activeModel) }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Input") {
                if appModel.micDevices.isEmpty {
                    Text("Using the system default microphone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: $appModel.selectedMicID) {
                        Text("Default").tag(String?.none)
                        ForEach(appModel.micDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                }
            }

            Section {
                Toggle("Show status pill near the notch", isOn: $appModel.showNotchPill)
                if NotchNeighbor.running {
                    Text("Vorssaint is running. Reflex's pill sits below its Dynamic Island and steps aside while the island is expanded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status Pill")
            } footer: {
                Text("A capsule light that appears below the notch (or the menu bar) while Reflex is listening or busy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button {
                    runDiagnostics()
                } label: {
                    Label("Run Diagnostics", systemImage: "stethoscope")
                }

                if let report {
                    HStack {
                        Text(report.ready ? "Ready" : "\(report.blockingCount) issue(s)")
                            .foregroundStyle(report.ready ? Color.secondary : Color.orange)
                        Spacer()
                        StatusPillView(light: appModel.statusLight)
                    }
                    .font(.caption)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.checks, id: \.name) { check in
                                DiagnosticsRow(check: check)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .font(.caption)
                }
            }

            Section("Session Logs") {
                HStack {
                    Button {
                        Clipboard.copy(appModel.lastSession?.markdown() ?? "")
                        appModel.modelStatus = "Copied last session logs"
                    } label: {
                        Label("Copy Last Session", systemImage: "doc.on.doc")
                    }
                    .disabled(appModel.lastSession == nil)

                    Button {
                        showHistory = true
                    } label: {
                        Label("History…", systemImage: "clock.arrow.circlepath")
                    }

                    Button {
                        presentExport(text: SessionLog.markdownAll(appModel.sessions),
                                      filename: "reflex-sessions.md")
                    } label: {
                        Label("Export All .md", systemImage: "square.and.arrow.up")
                    }
                    .disabled(appModel.sessions.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .sheet(isPresented: $showHistory) {
            LogHistoryView(
                sessions: appModel.sessions,
                onCopy: { session in
                    Clipboard.copy(session.markdown())
                    appModel.modelStatus = "Copied \(session.label) logs"
                },
                onExport: { session in
                    presentExport(text: session.markdown(), filename: "reflex-\(sanitized(session.label)).md")
                },
                onExportAll: {
                    presentExport(text: SessionLog.markdownAll(appModel.sessions),
                                  filename: "reflex-sessions.md")
                }
            )
        }
        .fileExporter(
            isPresented: $exporterShown,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                appModel.modelStatus = "Exported \(exportFilename)"
            case .failure(let error):
                appModel.modelStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func presentExport(text: String, filename: String) {
        exportDocument = MarkdownDocument(text: text)
        exportFilename = filename
        exporterShown = true
    }

    private func sanitized(_ label: String) -> String {
        label.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: " - ", with: "-")
            .replacingOccurrences(of: ":", with: "")
    }

    private func runDiagnostics() {
        let modelsDir = ReflexWhisperKit.defaultModelsDirectory
        Task.detached(priority: .userInitiated) {
            let result = SystemDiagnostics.run(probeMic: true, modelDirectory: modelsDir)
            await MainActor.run {
                report = result
                appModel.modelStatus = result.ready
                    ? "Diagnostics: all systems ready"
                    : "Diagnostics: \(result.blockingCount) issue(s)"
            }
        }
    }
}

private struct DiagnosticsRow: View {
    let check: SystemDiagnostics.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch check.status {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(check.name)
                        .fontWeight(.medium)
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                if let fix = check.howToFix {
                    Text(fix)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var detail: String {
        switch check.status {
        case .ok: "ok"
        case .warn(let message): message
        case .fail(let message): message
        case .info(let message): message
        }
    }
}
#endif

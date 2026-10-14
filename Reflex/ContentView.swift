import SwiftUI
import ReflexCore

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusLightView(light: appModel.statusLight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reflex")
                        .font(.largeTitle.bold())
                    Text("Always-on local assistant — speak, it acts.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            }

            Divider()

            if case .loading(let kind) = appModel.loadState {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading \(kind.displayName) into memory…")
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let message) = appModel.loadState {
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

            Picker("Model", selection: $appModel.activeModel) {
                ForEach(ReflexModelKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .disabled(appModel.isBusy)
            .onChange(of: appModel.activeModel) { _, kind in
                appModel.modelSelectionChanged(kind)
            }

            Toggle("Force English", isOn: $appModel.forcedEnglish)
                .disabled(appModel.isBusy)

            Toggle("Verbose session log", isOn: $appModel.verboseLogging)
                .disabled(appModel.isBusy)

            #if os(macOS)
            if !appModel.micDevices.isEmpty {
                Picker("Microphone", selection: $appModel.selectedMicID) {
                    Text("Default").tag(String?.none)
                    ForEach(appModel.micDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appModel.isBusy)
            }

            Toggle("Suppress while media playing", isOn: $appModel.suppressWhileMediaPlaying)
                .disabled(appModel.isBusy)
            #endif

            Divider()

            HStack(spacing: 10) {
                Button {
                    appModel.toggleListening()
                } label: {
                    Label(
                        appModel.isListening ? "Stop Listening" : "Start Listening",
                        systemImage: appModel.isListening ? "stop.fill" : "mic.fill"
                    )
                }
                .tint(appModel.isListening ? .red : .accentColor)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!appModel.loadState.isReady)

                if appModel.isListening {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appModel.isSpeaking ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(appModel.isSpeaking ? "Speaking" : "Listening")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if appModel.isListening {
                ProgressView(value: Double(min(appModel.liveLevel, 1.0)))
                    .progressViewStyle(.linear)
                    .frame(height: 4)
                HStack {
                    Text("⌘P kill switch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                if !appModel.liveText.isEmpty {
                    Text("… \(appModel.liveText)")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Status", value: appModel.modelStatus)

            if let decision = appModel.lastDecision {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcript: \(appModel.lastTranscript)")
                    Text("Target: \(decision.actionTarget.identifier), Urgency: \(decision.urgencyScore.rawValue), P(\(Int(decision.confidence.lowerBound * 100))–\(Int(decision.confidence.upperBound * 100)))%")
                        .font(.caption.monospaced())
                    if let trace = decision.trace {
                        let label = trace.ruleTarget ?? "–"
                        let text = trace.ambiguous
                            ? "⚠️ Laya said \(trace.layaTarget), rule said \(label)"
                            : "via \(trace.chosen)"
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(trace.ambiguous ? .orange : .secondary)
                    }
                }
                .textSelection(.enabled)
            }

            if let result = appModel.lastResult {
                Text(result.summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Divider()

            if !appModel.isListening, let session = appModel.lastSession {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Last session") {
                        Text("\(session.label) · \(session.entries.count) entr\(session.entries.count == 1 ? "y" : "ies")")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Button {
                            Clipboard.copy(session.markdown())
                            appModel.modelStatus = "Copied last session logs"
                        } label: {
                            Label("Copy Last Session Logs", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)

                        Button {
                            showHistory = true
                        } label: {
                            Label("Log History…", systemImage: "clock.arrow.circlepath")
                        }
                        .controlSize(.small)

                        Button {
                            presentExport(text: SessionLog.markdownAll(appModel.sessions),
                                          filename: "reflex-sessions.md")
                        } label: {
                            Label("Export All .md", systemImage: "square.and.arrow.up")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480)
        .sheet(isPresented: $showHistory) {
            LogHistoryView(
                sessions: appModel.sessions,
                onCopy: { session in
                    Clipboard.copy(session.markdown())
                    appModel.modelStatus = "Copied \(session.label) logs"
                },
                onExport: { session in
                    let safe = session.label
                        .replacingOccurrences(of: "/", with: "")
                        .replacingOccurrences(of: " - ", with: "-")
                        .replacingOccurrences(of: ":", with: "")
                    presentExport(text: session.markdown(), filename: "reflex-\(safe).md")
                },
                onExportAll: {
                    presentExport(text: SessionLog.markdownAll(appModel.sessions),
                                  filename: "reflex-sessions.md")
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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

    @State private var showHistory = false
    @State private var showSettings = false
    @State private var exportDocument: MarkdownDocument?
    @State private var exportFilename = "reflex-session.md"
    @State private var exporterShown = false

    private func presentExport(text: String, filename: String) {
        exportDocument = MarkdownDocument(text: text)
        exportFilename = filename
        exporterShown = true
    }
}

/// The session history popup: dd/mm/yy - hh:mm labels, per-session copy and
/// markdown export, plus a single export-all action.
private struct LogHistoryView: View {
    let sessions: [SessionLog]
    let onCopy: (SessionLog) -> Void
    let onExport: (SessionLog) -> Void
    let onExportAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session Log History")
                    .font(.headline)
                Spacer()
                Button("Export All .md") { onExportAll() }
                    .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No session logs yet.")
                        .foregroundStyle(.secondary)
                    Text("Enable “Verbose session log”, listen, then stop.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(sessions) { session in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.label)
                                .font(.body)
                            Text("\(session.entries.count) entries · \(session.entries.first?.mode == .live ? "live" : "segmented")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { onCopy(session) }
                            .buttonStyle(.borderless)
                            .help("Copy this session as markdown")
                        Button("Export", systemImage: "square.and.arrow.up") { onExport(session) }
                            .buttonStyle(.borderless)
                            .help("Save this session as .md")
                    }
                }
            }
        }
        .frame(width: 540, height: 400)
    }
}

/// The pulsing status LED (Phase C). Red = unavailable, Amber = busy,
/// Green = listening, dim = idle-ready. Mirrors the AirPods/PSP feedback.
private struct StatusLightView: View {
    let light: StatusLight
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .shadow(color: color.opacity(pulse ? 0.9 : 0.3), radius: pulse ? 6 : 2)
            .opacity(brightness)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear {
                guard light != .off else { return }
                pulse = true
            }
            .onChange(of: light) { _, new in
                pulse = new != .off
            }
            .help(helpText)
    }

    private var color: Color {
        switch light {
        case .red: .red
        case .amber: .orange
        case .green: .green
        case .off: .gray
        }
    }

    private var brightness: Double {
        switch light {
        case .off: 0.35
        case .green: pulse ? 1.0 : 0.6
        default: 1.0
        }
    }

    private var helpText: String {
        switch light {
        case .red(let reason): "Unavailable: \(reason)"
        case .amber(let reason): "Busy: \(reason)"
        case .green: "Listening"
        case .off: "Idle"
        }
    }
}

/// Settings sheet: toggles + in-app re-run of the `--diagnose` preflight so
/// permission issues surface without leaving the app.
private struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @State private var report: SystemDiagnostics.Report?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Toggle("Force English", isOn: $appModel.forcedEnglish)
                Toggle("Verbose session log", isOn: $appModel.verboseLogging)
                Toggle("Feedback sounds", isOn: $appModel.shouldPlayFeedbackSounds)

                Picker("Model", selection: $appModel.activeModel) {
                    ForEach(ReflexModelKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appModel.isBusy)
                .onChange(of: appModel.activeModel) { _, kind in
                    appModel.modelSelectionChanged(kind)
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            #if os(macOS)
            HStack {
                Button {
                    runDiagnostics()
                } label: {
                    Label("Run Diagnostics", systemImage: "stethoscope")
                }
                .controlSize(.regular)

                Spacer()
                StatusLightView(light: appModel.statusLight)
            }

            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Health check")
                            .font(.subheadline.bold())
                        Text(report.ready ? "· ready" : "· \(report.blockingCount) issue(s)")
                            .foregroundStyle(report.ready ? Color.secondary : Color.orange)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.checks, id: \.name) { check in
                                DiagnosticsRow(check: check)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption)
            }
            #else
            HStack {
                Text("Settings are macOS-only.")
                    .font(.caption)
                Spacer()
                StatusLightView(light: appModel.statusLight)
            }
            #endif
        }
        .padding(20)
        .frame(width: 460)
    }

    #if os(macOS)
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
    #endif
}

#if os(macOS)
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

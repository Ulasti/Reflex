import SwiftUI

/// The session history popup: dd/mm/yy - hh:mm labels, per-session copy and
/// markdown export, plus a single export-all action. Shared by the macOS
/// Settings window and the iOS dev screen.
struct LogHistoryView: View {
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

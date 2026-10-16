import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One user-visible action instance from a listening session: the transcript,
/// the target Laya/arbiter chose, the urgency score, the exact confidence
/// interval (the "P" the user sees), the routing trace values, and the action
/// outcome — everything gathered for a single decision.
struct SessionLog: Identifiable, Codable, Equatable, Sendable {
    enum Mode: String, Codable, Equatable, Sendable {
        case live, segmented
    }

    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let time: Date
        let mode: Mode
        let transcript: String
        let target: String
        let urgency: Int
        let confidenceLow: Double
        let confidenceHigh: Double
        let layaTarget: String?
        let ruleTarget: String?
        let chosen: String?
        let ambiguous: Bool
        let result: String
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var entries: [Entry]
}

extension SessionLog {
    /// "dd/mm/yy - hh:mm" — the history popup label for this session.
    var label: String { Self.dateLabel(endedAt ?? startedAt) }

    static func dateLabel(_ date: Date) -> String {
        Self.formatter("dd/MM/yy - HH:mm").string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        Self.formatter("HH:mm:ss").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    func markdown() -> String {
        let start = Self.dateLabel(startedAt)
        let end = Self.dateLabel(endedAt ?? startedAt)
        var lines: [String] = []
        lines.append("# Reflex Session — \(end)")
        lines.append("")
        lines.append("- Started: \(start), Ended: \(end)")
        lines.append("- Entries: \(entries.count)")
        if let mode = entries.first?.mode {
            lines.append("- Mode: \(mode == .live ? "as-you-speak (WhisperKit live)" : "segmented (whisper)")")
        }
        lines.append("")
        for (index, entry) in entries.enumerated() {
            lines.append("## \(index + 1). \(Self.timeLabel(entry.time)) — \"\(entry.transcript)\"")
            lines.append("- Mode: \(entry.mode == .live ? "live" : "segmented")")
            lines.append("- Target: \(entry.target)")
            lines.append("- Urgency: \(entry.urgency)")
            let low = Int((entry.confidenceLow * 100).rounded())
            let high = Int((entry.confidenceHigh * 100).rounded())
            lines.append("- Confidence: P(\(low)–\(high))%")
            let laya = entry.layaTarget ?? "–"
            let rule = entry.ruleTarget ?? "–"
            let chosen = entry.chosen ?? "–"
            let flag = entry.ambiguous ? " (ambiguous)" : ""
            lines.append("- Trace: Laya=\(laya), rule=\(rule), chosen=\(chosen)\(flag)")
            lines.append("- Action: \(entry.result)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func markdownAll(_ sessions: [SessionLog]) -> String {
        var body = "# Reflex — Session Log\n\n"
        body += sessions.map { $0.markdown() }.joined(separator: "\n\n---\n\n")
        body += "\n"
        return body
    }
}

/// File-backed history of completed sessions, newest first.
enum SessionLogStore {
    static func load() -> [SessionLog] {
        guard let data = try? Data(contentsOf: url()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionLog].self, from: data)) ?? []
    }

    static func save(_ sessions: [SessionLog]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = url().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: url(), options: .atomic)
    }

    private static func url() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Reflex/session-logs.json")
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}

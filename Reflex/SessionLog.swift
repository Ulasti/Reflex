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
        /// Wall clock at dispatch. Printed with milliseconds so the log can be
        /// read as a response-time timeline.
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
        /// Live latency, in milliseconds, from the points the app can see:
        /// speech onset → segment emit (the end-of-utterance wait), the final
        /// decode, routing, dispatch, and last voiced frame → dispatched (the
        /// number the demo's 500/700 ms target is stated in).
        let hearingMs: Double?
        let decodeMs: Double?
        let routeMs: Double?
        let dispatchMs: Double?
        let voiceToDispatchMs: Double?
        let emitReason: String?
        let audioDuration: Double?
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

    /// Session timestamps carry milliseconds: the log is read to compare
    /// response times, so seconds are too coarse.
    private static func stampLabel(_ date: Date) -> String {
        Self.formatter("dd/MM/yy HH:mm:ss.SSS").string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        Self.formatter("HH:mm:ss.SSS").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
    
    #if os(macOS)
    private static let gitCommit: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "unknown"
    }()
#else
    private static let gitCommit: String = "unknown"
#endif
    
    private static let buildDate: String = {
        let executablePath = Bundle.main.executablePath ?? ""
        let attrs = try? FileManager.default.attributesOfItem(atPath: executablePath)
        let date = attrs?[.modificationDate] as? Date
        return date.map { Self.formatter("yyyy-MM-dd HH:mm:ss").string(from: $0) } ?? "unknown"
    }()
    

    func markdown() -> String {
        let end = Self.dateLabel(endedAt ?? startedAt)
        var lines: [String] = []
        lines.append("# Reflex Session — \(end)")
        lines.append("")
        lines.append("- Started: \(Self.stampLabel(startedAt)), Ended: \(Self.stampLabel(endedAt ?? startedAt))")
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
            lines.append("- Latency: \(Self.latencyLabel(entry))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Live latency, read from a real session: last voiced frame → dispatched is
    /// the number the 500/700 ms target is stated in, and the terms add up to it.
    private static func latencyLabel(_ entry: Entry) -> String {
        func ms(_ value: Double?) -> String {
            value.map { "\(Int($0.rounded()))" } ?? "–"
        }
        var parts = ["voice→dispatch \(ms(entry.voiceToDispatchMs)) ms",
                     "hearing \(ms(entry.hearingMs))",
                     "decode \(ms(entry.decodeMs))",
                     "route \(ms(entry.routeMs))",
                     "dispatch \(ms(entry.dispatchMs))"]
        if entry.voiceToDispatchMs == nil { parts[0] = "voice→dispatch – (no voice window)" }
        return parts.joined(separator: ", ")
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
    /// ISO8601 with milliseconds. `JSONEncoder.dateEncodingStrategy = .iso8601`
    /// cuts to whole seconds, which would zero the milliseconds the markdown
    /// prints; decoding still accepts plain ISO8601 so older logs load.
    private static func iso8601Millis() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func load() -> [SessionLog] {
        guard let data = try? Data(contentsOf: url()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = iso8601Millis().date(from: text)
                ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "invalid ISO8601 date: \(text)"
                )
            }
            return date
        }
        return (try? decoder.decode([SessionLog].self, from: data)) ?? []
    }

    static func save(_ sessions: [SessionLog]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Millis().string(from: date))
        }
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

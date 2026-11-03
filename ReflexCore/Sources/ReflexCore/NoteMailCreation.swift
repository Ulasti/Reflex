import Foundation

/// Intent for creating a new note in a resolved container (account/folder).
public struct NoteCreationIntent: Sendable, Equatable {
    public let title: String
    public let body: String
    public let targetContainer: String?   // nil = default
    public let confidence: Double

    public init(title: String, body: String = "", targetContainer: String? = nil, confidence: Double = 0) {
        self.title = title
        self.body = body
        self.targetContainer = targetContainer
        self.confidence = confidence
    }
}

/// Intent for creating a new mail message in a resolved mailbox.
public struct MailCreationIntent: Sendable, Equatable {
    public let subject: String
    public let body: String
    public let recipients: [String]
    public let targetMailbox: String?     // nil = default drafts/sent
    public let confidence: Double

    public init(subject: String, body: String = "", recipients: [String] = [], targetMailbox: String? = nil, confidence: Double = 0) {
        self.subject = subject
        self.body = body
        self.recipients = recipients
        self.targetMailbox = targetMailbox
        self.confidence = confidence
    }
}

/// Resolves a spoken container name (folder/mailbox/account) to a concrete id.
public struct ContainerResolver: Sendable {
    public init() {}

    /// Normalize a spoken container name.
    public func normalize(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rank candidate containers by similarity; returns best match or nil.
    public func resolve(spoken: String, candidates: [String]) -> String? {
        let n = normalize(spoken)
        if n.isEmpty { return candidates.first }
        // Exact match first.
        if let exact = candidates.first(where: { $0.lowercased() == n }) { return exact }
        // Prefix / contains.
        if let pref = candidates.first(where: { $0.lowercased().hasPrefix(n) || $0.lowercased().contains(n) }) {
            return pref
        }
        return candidates.first
    }
}

public protocol NoteCreationAdapter: Sendable {
    func create(_ intent: NoteCreationIntent, container: String?) async throws -> Bool
}

public protocol MailCreationAdapter: Sendable {
    func create(_ intent: MailCreationIntent, mailbox: String?) async throws -> Bool
}

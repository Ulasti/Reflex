import Foundation

/// Snapshot of the active application/UI context at a point in time.
/// Platform providers populate what they can; missing fields stay nil and
/// `confidence` reflects how complete the snapshot is.
public struct AppContext: Sendable, Equatable {
    public let frontmostBundleID: String?
    public let frontmostAppName: String?
    public let windowTitle: String?
    public let focusedElementDescription: String?
    public let selectedText: String?
    public let capturedAt: Date
    public let confidence: Double

    public init(
        frontmostBundleID: String? = nil,
        frontmostAppName: String? = nil,
        windowTitle: String? = nil,
        focusedElementDescription: String? = nil,
        selectedText: String? = nil,
        capturedAt: Date = Date(),
        confidence: Double = 0
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppName = frontmostAppName
        self.windowTitle = windowTitle
        self.focusedElementDescription = focusedElementDescription
        self.selectedText = selectedText
        self.capturedAt = capturedAt
        self.confidence = confidence
    }

    /// True when the snapshot is too old to trust for a command that depends on
    /// UI state. Threshold is conservative; callers may override.
    public func isFresh(relativeTo now: Date = Date(), maxAge: TimeInterval = 1.0) -> Bool {
        now.timeIntervalSince(capturedAt) <= maxAge
    }
}

/// Supplies active application/UI context. Implementations are platform-specific
/// (macOS uses NSWorkspace + Accessibility; iOS uses the foreground scene).
/// The core engine depends only on this protocol.
public protocol AppContextProvider: Sendable {
    func currentContext() async -> AppContext
}

/// A provider that reports nothing. Used as the default when no platform
/// provider is wired in, so the engine degrades to global-only commands.
public struct NullAppContextProvider: AppContextProvider {
    public init() {}
    public func currentContext() async -> AppContext { AppContext() }
}

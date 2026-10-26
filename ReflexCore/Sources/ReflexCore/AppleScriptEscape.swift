/// One escaper for every AppleScript string literal. `ActionDispatcher`,
/// `BrowserController` and `ShortcutController` each carried their own copy
/// (atlas/docs/audit-2026-10-14.md, N2).
extension String {
    /// Escapes `\` and `"` so the receiver survives interpolation inside an
    /// AppleScript `"..."` literal.
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

#if os(macOS)
import ApplicationServices
#endif
import Foundation

/// A single keyboard shortcut: either a literal character (`keyChar`) or a
/// macOS virtual keycode (`keyCode`), with a set of modifiers. The `criteria`
/// list is the set of spoken phrases that map to this shortcut (used by
/// `canonicalName` to turn a transcript into a closed-set shortcut name).
public struct Shortcut: Sendable, Equatable {
    public let name: String
    public let keyChar: String?
    public let keyCode: UInt16?
    public let modifiers: [String]
    public let criteria: [String]

    public init(name: String, keyChar: String? = nil, keyCode: UInt16? = nil,
                modifiers: [String] = [], criteria: [String]) {
        self.name = name
        self.keyChar = keyChar
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.criteria = criteria
    }
}

/// The Jev-parity keyboard-shortcut catalog (System Events "press" table) plus
/// the spoken criteria that select each one. `canonicalName(in:)` returns the
/// best-matching shortcut name from a transcript; `press` executes it.
public enum ShortcutController {
    public static let catalog: [Shortcut] = [
        Shortcut(name: "enter", keyCode: 36, criteria: [
            "press enter", "hit enter", "press return", "hit return", "tap enter"
        ]),
        Shortcut(name: "escape", keyCode: 53, criteria: [
            "press escape", "hit escape", "press esc", "hit esc", "cancel", "dismiss it"
        ]),
        Shortcut(name: "tab", keyCode: 48, criteria: [
            "press tab", "hit tab", "press the tab key"
        ]),
        Shortcut(name: "space", keyCode: 49, criteria: [
            "press space", "hit space", "press the spacebar", "press spacebar"
        ]),
        Shortcut(name: "backspace", keyCode: 51, criteria: [
            "press backspace", "hit backspace", "delete the last thing"
        ]),
        Shortcut(name: "delete_forward", keyCode: 117, criteria: [
            "delete forward", "delete next", "press delete"
        ]),
        Shortcut(name: "arrow_up", keyCode: 126, criteria: [
            "press up", "press the up arrow", "press up arrow", "arrow up", "up arrow"
        ]),
        Shortcut(name: "arrow_down", keyCode: 125, criteria: [
            "press down", "press the down arrow", "press down arrow", "arrow down", "down arrow"
        ]),
        Shortcut(name: "arrow_left", keyCode: 123, criteria: [
            "press left", "press the left arrow", "press left arrow", "arrow left", "left arrow"
        ]),
        Shortcut(name: "arrow_right", keyCode: 124, criteria: [
            "press right", "press the right arrow", "press right arrow", "arrow right", "right arrow"
        ]),
        Shortcut(name: "copy", keyChar: "c", modifiers: ["command"], criteria: [
            "copy that", "copy it", "copy this", "copy the selection", "copy the text", "copy those"
        ]),
        Shortcut(name: "paste", keyChar: "v", modifiers: ["command"], criteria: [
            "paste", "paste that", "paste it", "paste this", "paste the text"
        ]),
        Shortcut(name: "cut", keyChar: "x", modifiers: ["command"], criteria: [
            "cut that", "cut it", "cut this", "cut the selection"
        ]),
        Shortcut(name: "undo", keyChar: "z", modifiers: ["command"], criteria: [
            "undo", "undo that", "undo it", "undo this"
        ]),
        Shortcut(name: "redo", keyChar: "z", modifiers: ["command", "shift"], criteria: [
            "redo", "redo that", "redo it"
        ]),
        Shortcut(name: "select_all", keyChar: "a", modifiers: ["command"], criteria: [
            "select all", "select everything", "select the whole page"
        ]),
        Shortcut(name: "save", keyChar: "s", modifiers: ["command"], criteria: [
            "save", "save it", "save the file", "save this", "save the document"
        ]),
        Shortcut(name: "find", keyChar: "f", modifiers: ["command"], criteria: [
            "find on this page", "find in this page", "search this page", "search in the page",
            "find in the document", "find in this document", "open find"
        ]),
        Shortcut(name: "new_document", keyChar: "n", modifiers: ["command"], criteria: [
            "new document", "make a new document", "create a new note"
        ]),
        Shortcut(name: "new_tab", keyChar: "t", modifiers: ["command"], criteria: [
            "new tab", "open a new tab"
        ]),
        Shortcut(name: "close_tab", keyChar: "w", modifiers: ["command"], criteria: [
            "close tab", "close this tab", "close window", "close this window"
        ]),
        Shortcut(name: "reopen_tab", keyChar: "t", modifiers: ["command", "shift"], criteria: [
            "reopen tab", "reopen the tab", "reopen closed tab", "undo close tab"
        ]),
        Shortcut(name: "quit_app", keyChar: "q", modifiers: ["command"], criteria: [
            "quit the app", "quit this app", "quit the application", "close the app"
        ]),
        Shortcut(name: "minimize", keyChar: "m", modifiers: ["command"], criteria: [
            "minimize", "minimize this window", "minimize the window", "minimize it"
        ]),
        Shortcut(name: "hide_app", keyChar: "h", modifiers: ["command"], criteria: [
            "hide the app", "hide this app", "hide the application", "hide it"
        ]),
        Shortcut(name: "fullscreen", keyChar: "f", modifiers: ["command", "control"], criteria: [
            "fullscreen", "full screen", "go fullscreen", "make it fullscreen", "enter fullscreen"
        ]),
        Shortcut(name: "next_tab_page", keyCode: 48, modifiers: ["control"], criteria: [
            "next tab", "go to the next tab"
        ]),
        Shortcut(name: "previous_tab_page", keyCode: 48, modifiers: ["control", "shift"], criteria: [
            "previous tab", "go back a tab", "last tab"
        ]),
        Shortcut(name: "browser_back", keyCode: 123, modifiers: ["command"], criteria: [
            "go back a page", "back a page", "previous page"
        ]),
        Shortcut(name: "browser_forward", keyCode: 124, modifiers: ["command"], criteria: [
            "go forward a page", "forward a page", "next page"
        ]),
        Shortcut(name: "reload", keyChar: "r", modifiers: ["command"], criteria: [
            "reload the page", "refresh the page", "reload this page", "refresh this page"
        ]),
        Shortcut(name: "address_bar", keyChar: "l", modifiers: ["command"], criteria: [
            "focus the address bar", "go to the address bar", "focus the url bar", "focus the location bar"
        ]),
        Shortcut(name: "spotlight", keyCode: 49, modifiers: ["command"], criteria: [
            "open spotlight", "spotlight search", "search with spotlight"
        ]),
        Shortcut(name: "switch_app", keyCode: 48, modifiers: ["command"], criteria: [
            "switch app", "switch the app", "app switcher", "switch application"
        ]),
        Shortcut(name: "next_window", keyChar: "`", modifiers: ["command"], criteria: [
            "next window", "switch window", "next window of this app", "cycle windows"
        ]),
        Shortcut(name: "line_start", keyCode: 123, modifiers: ["command", "shift"], criteria: [
            "select to the beginning", "select to start of line", "select to line start"
        ]),
        Shortcut(name: "line_end", keyCode: 124, modifiers: ["command", "shift"], criteria: [
            "select to the end", "select to end of line", "select to line end"
        ]),
        Shortcut(name: "delete_word", keyCode: 51, modifiers: ["option"], criteria: [
            "delete the word", "delete previous word", "delete last word", "delete that word"
        ]),
        Shortcut(name: "delete_line", keyCode: 51, modifiers: ["command"], criteria: [
            "delete the line", "delete this line", "delete the whole line"
        ]),
        Shortcut(name: "zoom_in", keyChar: "=", modifiers: ["command"], criteria: [
            "zoom in", "make it bigger", "make text bigger", "increase text size"
        ]),
        Shortcut(name: "zoom_out", keyChar: "-", modifiers: ["command"], criteria: [
            "zoom out", "make it smaller", "make text smaller", "decrease text size"
        ]),
        Shortcut(name: "bold", keyChar: "b", modifiers: ["command"], criteria: [
            "bold", "make it bold", "make that bold", "bold the text", "bold that"
        ]),
        Shortcut(name: "italic", keyChar: "i", modifiers: ["command"], criteria: [
            "italic", "make it italic", "italicize", "italicize that", "italics"
        ]),
        Shortcut(name: "send_message", keyCode: 36, modifiers: ["command"], criteria: [
            "send the message", "send message", "send this message", "send the chat"
        ]),
        Shortcut(name: "emoji_picker", keyCode: 49, modifiers: ["command", "control"], criteria: [
            "emoji picker", "open emoji", "add an emoji", "emoji"
        ]),
        Shortcut(name: "screenshot_region", keyChar: "4", modifiers: ["command", "shift"], criteria: [
            "take a screenshot of a region", "screenshot a region", "capture a region"
        ]),
        Shortcut(name: "lock_screen", keyChar: "q", modifiers: ["command", "control"], criteria: [
            "lock screen", "lock the screen", "lock my screen", "lock the mac"
        ]),
        Shortcut(name: "show_desktop", keyCode: 103, criteria: [
            "show desktop", "show the desktop", "reveal the desktop", "go to desktop"
        ]),
        Shortcut(name: "jump_top", keyCode: 126, modifiers: ["command"], criteria: [
            "jump to top", "jump to the top", "go to the top of the page", "go to the top"
        ]),
        Shortcut(name: "jump_bottom", keyCode: 125, modifiers: ["command"], criteria: [
            "jump to bottom", "jump to the bottom", "go to the bottom of the page", "go to the bottom"
        ]),
        Shortcut(name: "page_down", keyCode: 121, criteria: [
            "page down", "scroll a page down"
        ]),
        Shortcut(name: "page_up", keyCode: 116, criteria: [
            "page up", "scroll a page up"
        ]),
    ]

    /// Best-matching shortcut name for a transcript, or nil. Scored by the
    /// longest matching criteria phrase so "copy that path" doesn't collapse
    /// into plain copy when a more specific action won the routing.
    public static func canonicalName(in lowerTranscript: String) -> String? {
        // Past tense is the common slip ("pressed delete"): normalize it to the
        // imperative the catalog is written in before matching.
        let t = lowerTranscript.lowercased()
            .replacingOccurrences(of: "pressed ", with: "press ")
        var bestName: String?
        var bestLength = 0
        for shortcut in catalog {
            for phrase in shortcut.criteria {
                guard t.contains(phrase) else { continue }
                if phrase.count > bestLength {
                    bestLength = phrase.count
                    bestName = shortcut.name
                }
            }
        }
        return bestName
    }

    public static func shortcut(named name: String) -> Shortcut? {
        catalog.first { $0.name == name }
    }

    #if os(macOS)
    /// Presses a shortcut via System Events. Requires Accessibility.
    public static func press(_ shortcut: Shortcut) throws {
        try press(name: shortcut.name)
    }

    /// Presses a shortcut by catalog name.
    public static func press(name: String) throws {
        guard let shortcut = shortcut(named: name) else {
            throw ShortcutError.unknownShortcut(name)
        }
        try pressKey(shortcut)
    }

    private static func pressKey(_ shortcut: Shortcut) throws {
        let part: String
        if let keyChar = shortcut.keyChar {
            part = "keystroke \"\(Self.escape(keyChar))\""
        } else if let keyCode = shortcut.keyCode {
            part = "key code \(keyCode)"
        } else {
            throw ShortcutError.missingCode(shortcut.name)
        }
        let modifiersPart = modifiersAppleScript(shortcut.modifiers)
        let script = """
        tell application "System Events"
            \(part)\(modifiersPart.isEmpty ? "" : " using \(modifiersPart)")
        end tell
        """
        _ = try ActionDispatcher.runTool("/usr/bin/osascript", arguments: ["-e", script])
    }

    private static func modifiersAppleScript(_ modifiers: [String]) -> String {
        guard !modifiers.isEmpty else { return "" }
        let items = modifiers.map { "\($0) down" }
        return "{\(items.joined(separator: ", "))}"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    #endif
}

public enum ShortcutError: LocalizedError {
    case unknownShortcut(String)
    case missingCode(String)

    public var errorDescription: String? {
        switch self {
        case .unknownShortcut(let name): "No shortcut named \"\(name)\"."
        case .missingCode(let name): "Shortcut \"\(name)\" has neither a key char nor a keycode."
        }
    }
}

/// Real scroll-wheel events (Quartz) plus top/bottom jumps and amount steps,
/// ported from Jev's scroll controller. GCD event posting requires
/// Accessibility; the arrow-key fallback keeps scrolling usable without it.
public enum ScrollController {
    public enum Direction: Sendable, Equatable {
        case up, down, top, bottom
    }

    public enum Amount: Sendable, Equatable {
        case little, page, aLot

        var lines: Int {
            switch self {
            case .little: 5
            case .page: 15
            case .aLot: 40
            }
        }
    }

    public static func parse(direction: String?, amount: String?) -> (Direction, Amount)? {
        guard let direction else { return nil }
        let d: Direction = switch direction {
        case "top": .top
        case "bottom": .bottom
        case "down": .down
        default: .up
        }
        let a: Amount = switch amount {
        case "little": .little
        case "a_lot": .aLot
        default: .page
        }
        return (d, a)
    }

    #if os(macOS)
    /// Scrolls the frontmost app. `direction` ∈ up|down|top|bottom,
    /// `amount` ∈ little|page|a_lot. Real scroll-wheel events via Quartz;
    /// falls back to arrow keys / ⌘↑⌘↓ when the event tap isn't permitted.
    public static func scroll(direction: String?, amount: String?) throws {
        guard let (d, a) = parse(direction: direction, amount: amount) else {
            throw ActionExecutionError.parseFailure
        }
        switch d {
        case .top:
            try ShortcutController.press(name: "jump_top")
        case .bottom:
            try ShortcutController.press(name: "jump_bottom")
        case .up, .down:
            try postWheelLines(d == .down ? a.lines : -a.lines)
        }
    }

    private static func postWheelLines(_ lines: Int) throws {
        guard AXIsProcessTrusted() else {
            // No event-tap permission — do a coarse page scroll with the
            // arrow keys (Page Up/Down), which only needs Accessibility's
            // System Events support.
            try ShortcutController.press(name: lines > 0 ? "page_down" : "page_up")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let scroll = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(lines),
            wheel2: 0,
            wheel3: 0
        )
        scroll?.post(tap: .cghidEventTap)
    }
    #endif
}

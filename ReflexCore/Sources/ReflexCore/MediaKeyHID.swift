#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Posts AppleScript-free media-key HID events (NX play/pause/next/previous)
/// directly to the system event tap. This is the B3 fallback for browsers and
/// web apps that MediaRemote does not claim as a now-playing host.
public enum MediaKeyHID {
    /// NX key type constants (Carbon nxkeydefs values).
    private static let keyPlayPause: UInt32 = 16
    private static let keyNext: UInt32 = 17
    private static let keyPrevious: UInt32 = 18

    /// Maps our media intent to the HID media key and posts it if the event
    /// tap is permitted. Requires Accessibility (AXIsProcessTrusted).
    internal static func post(_ kind: ActionDispatcher.MediaKind) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let key: UInt32
        switch kind {
        case .play, .pause, .toggle: key = keyPlayPause
        case .next: key = keyNext
        case .previous: key = keyPrevious
        }
        postKey(key, down: true)
        postKey(key, down: false)
        return true
    }

    /// NX media-key events are system-defined events carrying the key code in
    /// high 16 bits and a subtype (0xA = pressed, 0xB = released) in low 16.
    /// `NSEvent.otherEvent` builds the proper `.systemDefined` event that the
    /// HID tap understands.
    private static func postKey(_ key: UInt32, down: Bool) {
        let subtype: Int16 = down ? 0xA : 0xB
        let data1 = (Int(key) << 16) | (Int(subtype) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        let cgEvent = event.cgEvent
        _ = cgEvent?.post(tap: .cghidEventTap)
    }
}
#endif

#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// Registers a global Carbon hotkey (⌘P) that steals nothing and requires no
/// Accessibility/Input Monitoring TCC grant. It fires even while the app is in
/// the background, which makes it a real mechanical kill switch for the
/// always-listening mode rather than a UI affordance.
enum HotKeyCenter {
    private static let signature: OSType = 0x52455846  // 'REFX'

    nonisolated(unsafe) private static var refs: [UInt32: EventHotKeyRef] = [:]
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private static let queue = DispatchQueue(label: "reflex.hotkey")

    static func register(
        keyCode: UInt32,
        modifiers: UInt32,
        id: UInt32,
        handler: @escaping () -> Void
    ) -> Bool {
        queue.sync {
            if !installed {
                var eventSpec = EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                )
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    Self.handleEvent,
                    1,
                    &eventSpec,
                    nil,
                    nil
                )
                installed = true
            }

            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            guard status == noErr, let hotKeyRef else { return false }
            refs[id] = hotKeyRef
            handlers[id] = handler
            return true
        }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, _ in
        var hotKeyID = EventHotKeyID()
        let error = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard error == noErr, let handler = HotKeyCenter.handlers[hotKeyID.id] else { return noErr }
        DispatchQueue.main.async {
            handler()
        }
        return noErr
    }
}
#endif

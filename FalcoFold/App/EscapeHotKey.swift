import Carbon.HIToolbox
import os

/// Esc as a global hot key. Carbon hot keys need no Accessibility permission. Register it only while the
/// effect is showing, so Esc keeps working normally in other apps the rest of the time.
final class EscapeHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "EscapeHotKey")

    var isRegistered: Bool { hotKeyRef != nil }

    /// `action` runs on the main queue when Esc is pressed.
    func register(action: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        self.action = action

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<EscapeHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action?() }
                return noErr
            }, 1, &eventType, context, &handlerRef)
            if status != noErr { log.error("InstallEventHandler failed: \(status)") }
        }

        let id = EventHotKeyID(signature: OSType(0x4646_4F4C), id: 1)   // "FFOL"
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            log.error("RegisterEventHotKey failed: \(status)")
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        action = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut that brings Perch down from the menu bar, from any
/// app, without asking for Accessibility access. Carbon's hot keys are old,
/// but they are still the one API that needs no permission for this.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    fileprivate static var fire: (() -> Void)?

    init?(_ combo: KeyCombo, action: @escaping () -> Void) {
        HotKey.fire = action
        HotKey.installHandler()
        let id = EventHotKeyID(signature: OSType(0x5052_4348), id: 1) // "PRCH"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.fire?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

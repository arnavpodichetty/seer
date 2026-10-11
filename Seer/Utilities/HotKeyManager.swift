import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts via Carbon's `RegisterEventHotKey`, which work while
/// other apps are focused and need no Accessibility permission.
final class HotKeyManager {
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    private var handlerRef: EventHandlerRef?

    /// Registers `shortcut` under `id`, replacing any previous one with that id.
    /// Returns false if another app already owns the key combination.
    @discardableResult
    func register(id: UInt32, _ shortcut: any GlobalShortcut, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
                                Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4C54), id: id)   // 'SPLT'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeys[id] = (ref, action)
        return true
    }

    func unregister(id: UInt32) {
        if let existing = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(existing.ref) }
    }

    fileprivate func fire(id: UInt32) { hotKeys[id]?.action() }
}

/// Carbon delivers hot key events on the main thread.
private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().fire(id: id)
    }
    return noErr
}

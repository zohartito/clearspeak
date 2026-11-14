import Carbon

public enum ReadShortcut: String, CaseIterable {
    case r, t, l
    public var title: String { "Control–Option–" + rawValue.uppercased() }
    public var symbols: String { "⌃⌥" + rawValue.uppercased() }
    public var pauseSymbols: String { "⌃⌥⇧" + rawValue.uppercased() }
    public var keyCode: UInt32 {
        switch self {
        case .r: return UInt32(kVK_ANSI_R)
        case .t: return UInt32(kVK_ANSI_T)
        case .l: return UInt32(kVK_ANSI_L)
        }
    }
}

/// Carbon hotkeys do not need Accessibility. Selection capture checks that separately.
/// Use on the application's main event thread.
public final class HotKeys {
    public var onPress: ((UInt32) -> Void)?
    public private(set) var activeShortcut: ReadShortcut?
    public private(set) var failures: [String] = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    public init() {}

    @discardableResult public func register(_ shortcut: ReadShortcut) -> Bool {
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                              MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                guard id.signature == 0x4353504B else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().onPress?(id.id)
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else {
                failures = ["Keyboard handler unavailable (macOS error \(result))."]
                return false
            }
        }
        let previous = activeShortcut
        unregisterBindings()
        failures = installBindings(shortcut)
        if failures.isEmpty { activeShortcut = shortcut; return true }
        // A failed change must not leave only some of the new keys registered.
        unregisterBindings()
        if let previous {
            let restoreErrors = installBindings(previous)
            if restoreErrors.isEmpty { activeShortcut = previous }
            else {
                unregisterBindings()
                failures += ["Previous shortcuts could not be restored."] + restoreErrors
            }
        }
        return false
    }

    private func installBindings(_ shortcut: ReadShortcut) -> [String] {
        let bindings: [(UInt32, UInt32, UInt32, String)] = [
            (1, shortcut.keyCode, UInt32(controlKey | optionKey), "Read " + shortcut.symbols),
            (2, shortcut.keyCode, UInt32(controlKey | optionKey | shiftKey), "Pause " + shortcut.pauseSymbols),
            (3, UInt32(kVK_Escape), UInt32(controlKey | optionKey), "Stop ⌃⌥Esc")
        ]
        var errors: [String] = []
        for (id, key, modifiers, name) in bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4353504B, id: id),
                                            GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else {
                let reason = status == OSStatus(eventHotKeyExistsErr) ? "already in use" : "macOS error \(status)"
                errors.append("\(name): \(reason).")
            }
        }
        return errors
    }
    private func unregisterBindings() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        activeShortcut = nil
    }
    public func unregister() {
        unregisterBindings()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit { unregister() }
}

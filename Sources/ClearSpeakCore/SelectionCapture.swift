import AppKit
import ApplicationServices

public enum CaptureError: LocalizedError {
    case permission, noSelection, secureField, changedApp, clipboardBusy, clipboardTooLarge
    public var errorDescription: String? {
        switch self {
        case .permission:
            return "macOS has not authorized this build of ClearSpeak. Quit and reopen ClearSpeak first. If its Accessibility switch is already on, remove that entry and add the current ClearSpeak app again. Paste & Read does not need Accessibility."
        case .noSelection: return "This app didn't expose selected text. Try the optional clipboard fallback in Settings, or copy and use Paste & Read."
        case .secureField: return "ClearSpeak won't capture password fields. Select ordinary text instead."
        case .changedApp: return "The active app changed during capture. Select the text again and retry."
        case .clipboardBusy: return "The clipboard changed during capture. Copy the selection yourself and use Paste & Read."
        case .clipboardTooLarge: return "The clipboard can't be safely backed up. Copy the selection yourself and use Paste & Read."
        }
    }
}

/// Exact representations, retained only in memory. Never overwrite a newer clipboard change.
@MainActor public struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    public init(_ pasteboard: NSPasteboard) throws {
        let before = pasteboard.changeCount
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw CaptureError.clipboardTooLarge }
                bytes += data.count
                guard bytes <= 20_000_000 else { throw CaptureError.clipboardTooLarge }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == before else { throw CaptureError.clipboardBusy }
        self.items = items
    }
    @discardableResult public func restore(_ pasteboard: NSPasteboard, ifUnchanged expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

@MainActor public final class SelectionCapture {
    public init() {}
    public static var hasPermission: Bool { AXIsProcessTrusted() }
    public static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func isSecure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    public func capture(pid: pid_t, clipboardFallback: Bool) async throws -> String {
        guard Self.hasPermission else { throw CaptureError.permission }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CaptureError.changedApp }
        if let focus = focusedElement(pid: pid) {
            guard !isSecure(focus) else { throw CaptureError.secureField }
            if let text = attribute(focus, kAXSelectedTextAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        guard clipboardFallback else { throw CaptureError.noSelection }
        // Wait for the shortcut's modifier keys to be released before synthesizing Cmd+C.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<30 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            throw CaptureError.clipboardBusy
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw CaptureError.changedApp }
        if let focus = focusedElement(pid: pid), isSecure(focus) { throw CaptureError.secureField }
        return try await captureClipboard(pasteboard: .general, copy: {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { throw CaptureError.noSelection }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(pid)
            up.postToPid(pid)
        }, isSameApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid })
    }
    /// Shared fallback path; explicit dependencies allow checks on private pasteboards without keystrokes.
    public func captureClipboard(pasteboard: NSPasteboard, copy: () throws -> Void,
                                 isSameApp: () -> Bool) async throws -> String {
        let original = try ClipboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        try copy()
        // Once Cmd+C is sent, complete cleanup even when the reading task is cancelled.
        for _ in 0..<20 {
            // An unstructured sleeper is not cancelled with the caller, so cleanup
            // still gives the target app time to finish its already-sent copy.
            await Task { try? await Task.sleep(nanoseconds: 50_000_000) }.value
            if pasteboard.changeCount != before {
                let copiedCount = pasteboard.changeCount
                // More than one write before a poll cannot be attributed to our Cmd+C.
                guard copiedCount == before + 1 else { throw CaptureError.clipboardBusy }
                let text = pasteboard.string(forType: .string)
                let sameApp = isSameApp()
                guard pasteboard.changeCount == copiedCount else { throw CaptureError.clipboardBusy }
                // A focus change means attribution is uncertain: leave the new clipboard alone.
                guard sameApp else { throw CaptureError.changedApp }
                guard original.restore(pasteboard, ifUnchanged: copiedCount) else { throw CaptureError.clipboardBusy }
                try Task.checkCancellation()
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.noSelection }
                return text
            }
        }
        try Task.checkCancellation()
        throw CaptureError.noSelection
    }
}

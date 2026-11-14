// Explicit local smoke check: quit ClearSpeak, then run from the repo root:
// swift scripts/check-login-launch.swift
// Launches the real signed app with a login-item event and leaves it running.
import AppKit
import CoreGraphics
let bundleID = "com.zohartito.clearspeak"
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
    print("FAIL: Quit ClearSpeak before this explicit launch check."); exit(1)
}
let event = NSAppleEventDescriptor(eventClass: kCoreEventClass,
    eventID: kAEOpenApplication, targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.appleEvent = event
var result: NSRunningApplication?
var failed = false
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/dist/ClearSpeak.app"), configuration: config) { app, error in
    result = app; failed = error != nil
}
let deadline = Date().addingTimeInterval(5)
while result == nil && !failed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
RunLoop.main.run(until: Date().addingTimeInterval(2))
guard let app = result, !failed, !app.isTerminated else { print("FAIL: Login-event launch failed."); exit(1) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let visible = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }.count
print("Login-event process:", app.processIdentifier, "visible windows:", visible)
guard visible == 0 else { print("FAIL: Login launch opened a window."); exit(1) }
print("PASS: Final app handles the login launch event without a window. App left running. Actual reboot not performed.")

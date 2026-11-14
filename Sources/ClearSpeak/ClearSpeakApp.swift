import AppKit
import Darwin

@main
struct ClearSpeakApp {
    @MainActor static func main() {
        // A crashed worker should produce an ordinary pipe error, not terminate the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

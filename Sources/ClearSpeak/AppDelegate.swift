import AppKit
import ClearSpeakCore
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let provider = LocalSpeechProvider()
    private lazy var playback = PlaybackController(provider: provider)
    private let capture = SelectionCapture()
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var readMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var dispatchID = UUID()
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var readerWindow: NSWindow?
    private var editor: NSTextView?
    private var modelStatus: NSTextField?
    private var modelDescription: NSTextField?
    private var voiceDetail: NSTextField?
    private var settingsPlaybackStatus: NSTextField?
    private var permissionStatus: NSTextField?
    private var launchAtLoginButton: NSButton?
    private var launchAtLoginStatus: NSTextField?
    private var readerStatus: NSTextField?
    private var readerPause: NSButton?
    private var readerStop: NSButton?
    private var shortcutPicker: NSPopUpButton?
    private var shortcutStatus: NSTextField?
    private var shortcutInstructions: NSTextField?
    private var shortcutTestButton: NSButton?
    private var shortcutTestTask: Task<Void, Never>?
    private var testingShortcut = false
    private var readShortcut: ReadShortcut {
        ReadShortcut(rawValue: UserDefaults.standard.string(forKey: "readShortcut") ?? "") ?? .r
    }
    private var voice: String {
        let value = UserDefaults.standard.string(forKey: "voice") ?? "Ryan"
        return LocalSpeechProvider.voices.contains(value) ? value : "Ryan"
    }
    private var clipboardFallback: Bool { UserDefaults.standard.bool(forKey: "clipboardFallback") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
        buildMainMenu()
        buildStatusMenu()
        playback.onChange = { [weak self] in self?.refreshStatus() }
        playback.onError = { [weak self] error in self?.showError(error) }
        let savedRate = UserDefaults.standard.float(forKey: "rate")
        playback.rate = savedRate == 0 ? 1 : min(2, max(0.5, savedRate))
        hotKeys.onPress = { [weak self] id in self?.handleShortcut(id) }
        hotKeys.register(readShortcut)
        refreshStatus()
        // Login launches should register the shortcuts without taking focus.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") { showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ClearSpeak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "ClearSpeak")
        statusItem.button?.toolTip = "ClearSpeak — natural reading"
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        readMenuItem = menuItem("Read Selection", #selector(readFromMenu))
        menu.addItem(readMenuItem)
        menu.addItem(menuItem("Paste & Read…", #selector(showReader)))
        pauseMenuItem = menuItem("Pause", #selector(togglePause))
        stopMenuItem = menuItem("Stop     ⌃⌥Esc", #selector(stop))
        menu.addItem(pauseMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(.separator())
        let rate = NSMenuItem(title: "Reading Speed", action: nil, keyEquivalent: "")
        let speeds = NSMenu()
        for value in [0.75, 1.0, 1.25, 1.5, 2.0] {
            let item = menuItem(String(format: "%.2g×", value), #selector(setRate(_:)))
            item.representedObject = value
            speeds.addItem(item)
        }
        rate.submenu = speeds
        menu.addItem(rate)
        menu.addItem(menuItem("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit ClearSpeak", #selector(quit)))
        statusItem.menu = menu
    }
    private func refreshStatus() {
        let status = captureTask != nil ? "Getting selection…" : playback.status
        statusMenuItem?.title = status
        readerStatus?.stringValue = status
        settingsPlaybackStatus?.stringValue = status
        let shortcut = hotKeys.activeShortcut ?? readShortcut
        readMenuItem?.title = "Read Selection     " + (hotKeys.activeShortcut == nil ? "(shortcut unavailable)" : shortcut.symbols)
        pauseMenuItem?.title = (playback.isPaused ? "Resume" : "Pause") + "     " + (hotKeys.activeShortcut == nil ? "(shortcut unavailable)" : shortcut.pauseSymbols)
        stopMenuItem?.title = "Stop     " + (hotKeys.activeShortcut == nil ? "(shortcut unavailable)" : "⌃⌥Esc")
        pauseMenuItem?.isEnabled = playback.isActive
        stopMenuItem?.isEnabled = playback.isActive || captureTask != nil
        readerPause?.title = playback.isPaused ? "Resume" : "Pause"
        readerPause?.isEnabled = playback.isActive
        readerStop?.isEnabled = playback.isActive || captureTask != nil
        statusItem.button?.image = NSImage(systemSymbolName: playback.isActive ? "waveform.circle.fill" : "waveform",
                                           accessibilityDescription: "ClearSpeak: \(status)")
        if let submenu = statusItem.menu?.items.first(where: { $0.title == "Reading Speed" })?.submenu {
            for item in submenu.items {
                item.state = abs((item.representedObject as? Double ?? 0) - Double(playback.rate)) < 0.01 ? .on : .off
            }
        }
    }
    private func readSelection(expectedPID: pid_t? = nil) {
        dispatchID = UUID()
        guard captureTask == nil else { return }
        do {
            guard provider.isInstalled(voice: voice) else { throw SpeechError.runtimeMissing }
            guard let app = NSWorkspace.shared.frontmostApplication else { throw CaptureError.changedApp }
            if let expectedPID, app.processIdentifier != expectedPID { throw CaptureError.changedApp }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw CaptureError.noSelection
            }
            guard SelectionCapture.hasPermission else { throw CaptureError.permission }
            if playback.isActive { playback.stop() }
            let id = UUID()
            captureID = id
            captureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await self.capture.capture(pid: app.processIdentifier, clipboardFallback: self.clipboardFallback)
                    try Task.checkCancellation()
                    guard self.captureID == id else { return }
                    try self.playback.read(text, voice: self.voice)
                } catch {
                    if self.captureID == id && !(error is CancellationError) { self.showError(error) }
                }
                if self.captureID == id { self.captureTask = nil; self.refreshStatus() }
            }
            refreshStatus()
        } catch { showError(error) }
    }
    @objc private func readFromMenu() {
        if let app = lastExternalApp, !app.isTerminated {
            let id = UUID()
            dispatchID = id
            app.activate(options: [])
            Task { @MainActor in
                // Wait for the intended app, and never capture a different foreground app.
                for _ in 0..<20 {
                    guard self.dispatchID == id else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard self.dispatchID == id else { return }
                self.readSelection(expectedPID: app.processIdentifier)
            }
        } else { readSelection() }
    }
    @objc private func togglePause() { playback.togglePause() }
    @objc private func stop() {
        dispatchID = UUID()
        captureID = UUID()
        captureTask?.cancel()
        // Keep the capture lock until clipboard cleanup finishes.
        if let pending = captureTask {
            Task { @MainActor in
                await pending.value
                self.captureTask = nil
                self.refreshStatus()
            }
        }
        playback.stop()
        refreshStatus()
    }
    @objc private func setRate(_ item: NSMenuItem) {
        playback.rate = Float(item.representedObject as? Double ?? 1)
        UserDefaults.standard.set(playback.rate, forKey: "rate")
        refreshStatus()
    }
    @objc private func quit() { stop(); NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pending = captureTask else { return .terminateNow }
        stop()
        Task { @MainActor in
            await pending.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { playback.stop() }

    private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return field
    }
    private func button(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }
    private func makeWindow(title: String, width: CGFloat, views: [NSView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height + 48))
        window.center()
        return window
    }
    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let fallback = NSButton(checkboxWithTitle: "Use Cmd+C when an app won't expose its selection", target: self, action: #selector(setFallback(_:)))
            fallback.state = clipboardFallback ? .on : .off
            permissionStatus = label("")
            modelStatus = label("")
            modelDescription = label("")
            voiceDetail = label("", size: 11)
            settingsPlaybackStatus = label(playback.status)
            let voicePicker = NSPopUpButton()
            var choices = provider.availableVoices
            if !choices.contains(voice) { choices.append(voice) }
            voicePicker.addItems(withTitles: choices)
            voicePicker.selectItem(withTitle: voice)
            voicePicker.target = self
            voicePicker.action = #selector(setVoice(_:))
            let picker = NSPopUpButton()
            picker.addItems(withTitles: ReadShortcut.allCases.map(\.title))
            picker.selectItem(at: ReadShortcut.allCases.firstIndex(of: readShortcut) ?? 0)
            picker.target = self
            picker.action = #selector(setShortcut(_:))
            shortcutPicker = picker
            shortcutStatus = label("", size: 12)
            shortcutInstructions = label("", size: 12)
            shortcutTestButton = button("Test Shortcut", action: #selector(testShortcut))
            launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at login", target: self,
                                          action: #selector(setLaunchAtLogin(_:)))
            launchAtLoginStatus = label("", size: 11)
            settingsWindow = makeWindow(title: "ClearSpeak Settings", width: 570, views: [
                label("Natural speech. Entirely on your Mac.", size: 23, bold: true),
                label("Highlight text in another app, then use the reading shortcut below."),
                row([launchAtLoginButton!, button("Login Items…", action: #selector(openLoginItems))]),
                launchAtLoginStatus!,
                label("Close this window to keep ClearSpeak in the menu bar. Quit stops the shortcuts until you reopen it or log in again.", size: 11),
                label("Local voice", size: 15, bold: true),
                modelDescription!,
                modelStatus!,
                label("No account, API key, subscription, or per-use charge. Your text stays on this Mac. The speech engine runs with network access blocked; text and audio are kept in memory and no reading history is saved."),
                row([label("Voice"), voicePicker, button("Listen to Sample", action: #selector(sample))]),
                settingsPlaybackStatus!,
                voiceDetail!,
                label("The first reading loads the model. It stays ready for the next passage. Unload it when you want to free memory.", size: 11),
                row([button("Unload Model", action: #selector(unloadModel))]),
                label("Read selections", size: 15, bold: true),
                row([permissionStatus!, button("Accessibility Settings…", action: #selector(enableAccessibility))]),
                fallback,
                label("The optional fallback briefly copies your selection, then restores the clipboard if it has not changed again. Clipboard managers may retain that copy. Leave it off if you prefer to paste manually.", size: 11),
                row([label("Read shortcut"), picker, shortcutTestButton!]),
                shortcutInstructions!,
                shortcutStatus!,
                row([button("Paste & Read…", action: #selector(showReader))])
            ])
        }
        refreshSettings()
        refreshShortcutSettings()
        present(settingsWindow)
    }
    private func refreshSettings() {
        modelDescription?.stringValue = LocalSpeechProvider.modelName(for: voice)
        modelStatus?.stringValue = provider.isInstalled(voice: voice) ? "Model installed · Ready for offline reading" : "Local model setup needed — see README"
        voiceDetail?.stringValue = LocalSpeechProvider.detail(for: voice)
        permissionStatus?.stringValue = SelectionCapture.hasPermission ? "Accessibility enabled" : "macOS has not authorized this build"
        refreshLaunchAtLogin()
    }
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginButton?.state = status == .enabled || status == .requiresApproval ? .on : .off
        switch status {
        case .enabled:
            launchAtLoginStatus?.stringValue = "Starts in the menu bar whenever you log in, including after a restart."
        case .requiresApproval:
            launchAtLoginStatus?.stringValue = "Allow ClearSpeak in System Settings → General → Login Items to finish enabling startup."
        case .notRegistered:
            launchAtLoginStatus?.stringValue = "Automatic startup is off. Open ClearSpeak to use the shortcuts."
        case .notFound:
            launchAtLoginStatus?.stringValue = "macOS couldn't find this login item. Reopen ClearSpeak and enable Launch at login again."
        @unknown default:
            launchAtLoginStatus?.stringValue = "Check ClearSpeak's startup status in Login Items."
        }
    }
    @objc private func setLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLogin()
            if SMAppService.mainApp.status == .requiresApproval { openLoginItems() }
        } catch {
            refreshLaunchAtLogin()
            launchAtLoginStatus?.stringValue = "macOS couldn't change automatic startup. Open Login Items to check ClearSpeak's setting."
        }
    }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { refreshSettings() }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { endShortcutTest() }
        if notification.object as? NSWindow === readerWindow { editor?.string = "" }
    }
    private func refreshShortcutSettings() {
        let shortcut = hotKeys.activeShortcut ?? readShortcut
        shortcutPicker?.selectItem(at: ReadShortcut.allCases.firstIndex(of: shortcut) ?? 0)
        shortcutInstructions?.stringValue = "Read: " + shortcut.symbols + "   ·   Pause/resume: " + shortcut.pauseSymbols + "   ·   Stop: ⌃⌥Esc"
        shortcutTestButton?.isEnabled = hotKeys.activeShortcut != nil
        if hotKeys.failures.isEmpty {
            shortcutStatus?.stringValue = "Shortcuts registered. Test Shortcut checks key detection without reading text."
        } else {
            shortcutStatus?.stringValue = hotKeys.failures.joined(separator: " ") +
                (hotKeys.activeShortcut == nil ? " Use menu controls or choose other keys." : " Previous keys remain active.")
        }
    }
    @objc private func setShortcut(_ sender: NSPopUpButton) {
        endShortcutTest()
        let selected = ReadShortcut.allCases[sender.indexOfSelectedItem]
        if hotKeys.register(selected) { UserDefaults.standard.set(selected.rawValue, forKey: "readShortcut") }
        refreshShortcutSettings()
        refreshStatus()
    }
    @objc private func testShortcut() {
        if testingShortcut { endShortcutTest(); refreshShortcutSettings(); return }
        guard let shortcut = hotKeys.activeShortcut else { return }
        testingShortcut = true
        shortcutTestButton?.title = "Cancel Test"
        shortcutStatus?.stringValue = "Press " + shortcut.title + " within 20 seconds. No text will be read."
        shortcutTestTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self else { return }
            self.endShortcutTest()
            self.shortcutStatus?.stringValue = "No key press received. Try another shortcut above; menu and Paste & Read remain available."
        }
    }
    private func endShortcutTest() {
        shortcutTestTask?.cancel()
        shortcutTestTask = nil
        testingShortcut = false
        shortcutTestButton?.title = "Test Shortcut"
    }
    private func handleShortcut(_ id: UInt32) {
        guard (1...3).contains(id) else { return }
        let action = id == 1 ? "Read" : (id == 2 ? "Pause/resume" : "Stop")
        if testingShortcut {
            endShortcutTest()
            shortcutStatus?.stringValue = action + " shortcut received. " +
                (SelectionCapture.hasPermission ? "Accessibility is enabled." : "macOS has not authorized this build for selection reading.")
            return
        }
        shortcutStatus?.stringValue = action + " shortcut received."
        switch id {
        case 1:
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                readFromMenu()
            } else { readSelection() }
        case 2: playback.togglePause()
        case 3: stop()
        default: break
        }
    }
    @objc private func setFallback(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "clipboardFallback") }
    @objc private func setVoice(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.titleOfSelectedItem ?? "Ryan", forKey: "voice")
        refreshSettings()
    }
    @objc private func unloadModel() { stop(); modelStatus?.stringValue = "Model unloaded · Loads again on your next reading" }
    @objc private func enableAccessibility() {
        SelectionCapture.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func sample() {
        startReading("Take a breath. You don't need to read everything at once. ClearSpeak can read this passage aloud while you look away, think, or keep working.")
    }
    private func startReading(_ text: String) {
        dispatchID = UUID()
        guard captureTask == nil else { return }
        do { try playback.read(text, voice: voice) }
        catch { showError(error) }
    }
    @objc private func showReader() {
        if readerWindow == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 522, height: 240))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.widthAnchor.constraint(equalToConstant: 522).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
            text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.font = .systemFont(ofSize: 15)
            text.textContainerInset = NSSize(width: 10, height: 10)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.minSize = NSSize(width: 0, height: 240)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.autoresizingMask = .width
            text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            editor = text
            readerStatus = label(playback.status)
            readerPause = button("Pause", action: #selector(togglePause))
            readerStop = button("Stop", action: #selector(stop))
            let read = button("Read Aloud", action: #selector(readEditor))
            read.keyEquivalent = "\r"
            read.keyEquivalentModifierMask = .command
            readerWindow = makeWindow(title: "ClearSpeak — Paste & Read", width: 570, views: [
                label("Give your eyes a break.", size: 23, bold: true),
                label("Paste text below, then read it aloud. ⌘Return to start."), scroll,
                row([button("Paste", action: #selector(pasteText)), button("Clear", action: #selector(clearText)), read, readerPause!, readerStop!]),
                readerStatus!,
                label("AI-generated speech runs entirely on this Mac. No text is uploaded or saved in a reading history. Closing this window clears the text.", size: 11)
            ])
        }
        refreshStatus()
        present(readerWindow)
        readerWindow?.makeFirstResponder(editor)
    }
    @objc private func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { showError(SpeechError.emptyText); return }
        guard text.utf8.count <= 50_000 else { showError(SpeechError.tooLong); return }
        editor?.string = text
    }
    @objc private func clearText() { editor?.string = "" }
    @objc private func readEditor() { startReading(editor?.string ?? "") }
    private func showError(_ error: Error) {
        let alert = NSAlert()
        let permissionError: Bool
        if let captureError = error as? CaptureError, case .permission = captureError { permissionError = true }
        else { permissionError = false }
        alert.messageText = permissionError ? "macOS hasn't authorized this ClearSpeak build" : "ClearSpeak"
        // Do not expose third-party errors that could include selected text.
        if error is SpeechError || error is CaptureError {
            alert.informativeText = error.localizedDescription
        } else {
            alert.informativeText = "The local speech engine couldn't finish. Unload the model and try again."
        }
        if permissionError {
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Paste & Read")
            alert.addButton(withTitle: "Cancel")
        } else { alert.addButton(withTitle: "OK") }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if permissionError {
            if response == .alertFirstButtonReturn { enableAccessibility() }
            else if response == .alertSecondButtonReturn { showReader() }
        }
    }
}

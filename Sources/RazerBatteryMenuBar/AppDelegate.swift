import AppKit

/// Owns the menu-bar status item, the dropdown menu, and the refresh loop.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = BatteryMonitor()
    private var timer: Timer?
    private var status = HeadsetStatus.disconnected

    /// Informational (auto-disabled) menu rows we update on each refresh.
    private let batteryItem = NSMenuItem()
    private let chargingItem = NSMenuItem()
    private let connectionItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private let diagnosticItem = NSMenuItem()
    private var loginItem: NSMenuItem!

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let refreshInterval: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎧 …"
        buildMenu()

        // Start the persistent HID listener; refresh immediately when a
        // battery/charging broadcast arrives (e.g. on plug/unplug).
        monitor.start { [weak self] in self?.refresh() }

        // React to audio output device changes immediately.
        monitor.audio.start { [weak self] in self?.refresh() }

        // Periodic refresh.
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.audio.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        monitor.audio.stop()
        monitor.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "Razer Barracuda", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in [batteryItem, chargingItem, connectionItem, audioItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        diagnosticItem.isEnabled = false
        menu.addItem(diagnosticItem)
        menu.addItem(.separator())

        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        apply(status)
        updateLoginState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLoginState()
        refresh()
    }

    // MARK: - Actions

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        updateLoginState()
    }

    private func updateLoginState() {
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    // MARK: - Refresh

    private func refresh() {
        monitor.refresh { [weak self] status in
            self?.apply(status)
        }
    }

    private func apply(_ status: HeadsetStatus) {
        self.status = status
        statusItem.button?.title = StatusFormatter.menuBarTitle(status)
        batteryItem.title = StatusFormatter.batteryLine(status)
        chargingItem.title = StatusFormatter.chargingLine(status)
        connectionItem.title = StatusFormatter.connectionLine(status)
        audioItem.title = StatusFormatter.audioLine(status)
        updatedItem.title = "Updated: " + AppDelegate.timeFormatter.string(from: status.lastUpdated)
        diagnosticItem.title = status.diagnosticMessage ?? ""
        diagnosticItem.isHidden = status.diagnosticMessage == nil
    }
}

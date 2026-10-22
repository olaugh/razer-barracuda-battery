import AppKit

// CLI subcommands that don't launch the menu-bar UI. Useful for development
// and for calibrating the HID protocol against a real headset.
let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    RazerBatteryMenuBar — Razer Barracuda X (2022) / X Chroma battery monitor

    Usage:
      RazerBatteryMenuBar               Launch the menu-bar app
      RazerBatteryMenuBar --once        Print current status once and exit
      RazerBatteryMenuBar --probe       Dump HID feature reports (protocol calibration)
      RazerBatteryMenuBar --list-devices  List all HID devices and report sizes
      RazerBatteryMenuBar --login-status  Print launch-at-login status
    """)
    exit(0)
}

if arguments.contains("--probe") {
    HIDProbe.run()
    exit(0)
}

if let idx = arguments.firstIndex(of: "--listen") {
    let seconds = (idx + 1 < arguments.count ? Double(arguments[idx + 1]) : nil) ?? 30
    HIDProbe.listen(seconds: seconds)
    exit(0)
}

if arguments.contains("--snapshot") {
    HIDProbe.snapshot()
    exit(0)
}

if let idx = arguments.firstIndex(of: "--watch") {
    let seconds = (idx + 1 < arguments.count ? Double(arguments[idx + 1]) : nil) ?? 20
    HIDProbe.watch(seconds: seconds)
    exit(0)
}

if arguments.contains("--list-devices") {
    HIDProbe.listDevices()
    exit(0)
}

if arguments.contains("--once") {
    let monitor = BatteryMonitor()
    print(monitor.readNow().description)
    exit(0)
}

if arguments.contains("--login-status") {
    print("Launch at login: \(LoginItem.statusDescription)")
    exit(0)
}

// Verification only: register → check → unregister (leaves no persistent login
// item). Must be launched via `open` so it runs in the proper LaunchServices
// context. Writes the outcome to a file since `open` doesn't capture stdout.
if arguments.contains("--selftest-login") {
    var out = "before:    \(LoginItem.statusDescription)\n"
    let reg = LoginItem.setEnabled(true)
    out += "register:  ok=\(reg) → \(LoginItem.statusDescription)\n"
    let unreg = LoginItem.setEnabled(false)
    out += "unregister: ok=\(unreg) → \(LoginItem.statusDescription)\n"
    try? out.write(toFile: "/tmp/razer_login_selftest.txt", atomically: true, encoding: .utf8)
    exit(0)
}

// Standalone live HID monitor window (regular app with a Dock icon).
if arguments.contains("--monitor") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let launcher = MonitorLauncher()
    app.delegate = launcher
    app.run()
    exit(0)
}

// Default: run as a menu-bar (accessory) app with no Dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

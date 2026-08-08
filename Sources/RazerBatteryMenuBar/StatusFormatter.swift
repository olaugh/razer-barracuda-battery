import Foundation

/// Turns a `HeadsetStatus` into the strings shown in the menu bar and dropdown.
enum StatusFormatter {

    /// The inline menu-bar title, e.g. "🎧 85%" or "🎧 85% ⚡".
    /// Text is drawn with the system label color, so it adapts to light/dark
    /// menu bars automatically.
    static func menuBarTitle(_ s: HeadsetStatus) -> String {
        guard s.isConnected else { return "🎧 —" }
        guard let pct = s.batteryPercent else {
            // Connected, battery not decoded: show the icon (charging bolt only
            // if charging is actually known to be true).
            return s.isCharging == true ? "🎧 ⚡" : "🎧"
        }
        return s.isCharging == true ? "🎧 \(pct)% ⚡" : "🎧 \(pct)%"
    }

    static func batteryLine(_ s: HeadsetStatus) -> String {
        "Battery: " + (s.batteryPercent.map { "\($0)%" } ?? (s.isConnected ? "Unknown" : "—"))
    }

    static func chargingLine(_ s: HeadsetStatus) -> String {
        guard s.isConnected else { return "Status: —" }
        switch s.isCharging {
        case .some(true):  return "Status: Charging ⚡"
        case .some(false): return "Status: Not charging"
        case .none:        return "Status: Unknown"
        }
    }

    static func connectionLine(_ s: HeadsetStatus) -> String {
        "Connection: " + s.connection.rawValue
    }

    static func audioLine(_ s: HeadsetStatus) -> String {
        "Audio Output: " + (s.audioActive ? "Active (primary)" : "Inactive")
    }
}

import Foundation

/// How the headset is currently talking to the Mac.
enum ConnectionType: String {
    case dongle = "2.4 GHz Dongle"
    case bluetooth = "Bluetooth"
    case disconnected = "Disconnected"
}

/// A snapshot of everything we know about the headset at one moment.
struct HeadsetStatus {
    var isConnected: Bool
    /// 0...100, or nil when connected but the level couldn't be read/decoded.
    var batteryPercent: Int?
    /// true/false when known; nil when charging state can't be determined.
    var isCharging: Bool?
    var connection: ConnectionType
    /// True when the Barracuda is the current macOS default audio output.
    var audioActive: Bool
    var lastUpdated: Date
    /// False when a dongle exists but its wireless-link query failed.
    var connectionKnown: Bool = true
    var diagnosticMessage: String? = nil

    static var disconnected: HeadsetStatus {
        HeadsetStatus(
            isConnected: false,
            batteryPercent: nil,
            isCharging: nil,
            connection: .disconnected,
            audioActive: false,
            lastUpdated: Date()
        )
    }

    /// Plain-text summary used by the `--once` CLI mode.
    var description: String {
        let batt = batteryPercent.map { "\($0)%" } ?? "unknown"
        let charge = isCharging.map { $0 ? "yes" : "no" } ?? "unknown"
        return """
        Connected:   \(connectionKnown ? String(isConnected) : "unknown")
        Battery:     \(batt)
        Charging:    \(charge)
        Connection:  \(connection.rawValue)
        Audio active:\(audioActive)
        """ + (diagnosticMessage.map { "\nDiagnostic:  " + $0 } ?? "")
    }
}

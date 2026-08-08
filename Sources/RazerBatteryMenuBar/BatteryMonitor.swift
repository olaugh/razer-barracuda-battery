import Foundation

/// Aggregates the dongle listener (HID broadcasts), the Bluetooth fallback, and
/// the CoreAudio monitor into a single `HeadsetStatus`. All work runs on the
/// main thread — the reads are fast and the HID listener is main-thread-affine.
final class BatteryMonitor {

    private let listener = HIDStateListener.shared
    private let bluetooth = BluetoothBatteryReader()
    let audio = AudioMonitor()

    /// Start the persistent HID listener. `onUpdate` fires when a broadcast
    /// changes battery/charging so the UI can refresh immediately.
    func start(onUpdate: @escaping () -> Void) {
        listener.onUpdate = onUpdate
        listener.start()
    }

    func refresh(_ completion: @escaping (HeadsetStatus) -> Void) {
        completion(readNow())
    }

    func readNow() -> HeadsetStatus {
        let audioActive = audio.isRazerActive()

        // 1) Dongle path — battery/charging come from the async HID listener.
        listener.poll()
        if listener.present {
            // Charging is only announced on change (plug/unplug); until we've
            // heard a charge record, assume "not charging" — the common case,
            // and it never shows a false charging bolt (that needs a real 0x2a).
            return HeadsetStatus(
                isConnected: true,
                batteryPercent: listener.battery,
                isCharging: listener.charging ?? false,
                connection: .dongle,
                audioActive: audioActive,
                lastUpdated: Date()
            )
        }

        // 2) Bluetooth fallback (IORegistry BatteryPercent).
        let bt = bluetooth.read()
        if bt.present {
            return HeadsetStatus(
                isConnected: true,
                batteryPercent: bt.battery,
                isCharging: nil,
                connection: .bluetooth,
                audioActive: audioActive,
                lastUpdated: Date()
            )
        }

        // 3) Not found on either transport.
        var status = HeadsetStatus.disconnected
        status.audioActive = audioActive
        return status
    }
}

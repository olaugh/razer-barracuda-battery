import Foundation

/// Aggregates the dongle listener (HID broadcasts), the Bluetooth fallback, and
/// the CoreAudio monitor into a single `HeadsetStatus`. Chroma callbacks stay
/// on the main thread; 2022 command exchanges run on a serial worker queue.
final class BatteryMonitor {

    private let listener = HIDStateListener.shared
    private let bluetooth = BluetoothBatteryReader()
    let audio = AudioMonitor()
    private let queue = DispatchQueue(label: "com.olaugh.RazerBatteryMenuBar.dongle2022")
    private let dongleRead: () -> BarracudaX2022Reading?
    private let fallbackRead: (() -> HeadsetStatus)?
    private var pending: [(HeadsetStatus) -> Void] = []
    private var reading = false
    private var stopping = false

    init(dongleRead: @escaping () -> BarracudaX2022Reading? = BarracudaX2022Reader.read,
         fallbackRead: (() -> HeadsetStatus)? = nil) {
        self.dongleRead = dongleRead
        self.fallbackRead = fallbackRead
    }

    /// Start the persistent HID listener. `onUpdate` fires when a broadcast
    /// changes battery/charging so the UI can refresh immediately.
    func start(onUpdate: @escaping () -> Void) {
        listener.onUpdate = onUpdate
        listener.start()
    }

    func refresh(_ completion: @escaping (HeadsetStatus) -> Void) {
        guard !stopping else { return }
        let fallback = readFallback()
        // Preserve the Chroma dongle path exactly; it never receives PA commands.
        if fallback.connection == .dongle {
            completion(fallback)
            return
        }
        pending.append(completion)
        guard !reading else { return }
        reading = true
        queue.async {
            let result = self.dongleRead()
            DispatchQueue.main.async {
                self.reading = false
                let current = self.readFallback()
                let status = self.resolve(result, fallback: current)
                let callbacks = self.pending
                self.pending = []
                if !self.stopping { callbacks.forEach { $0(status) } }
            }
        }
    }

    /// Normal quit waits for a transaction (including route cleanup) to finish.
    func stop(_ completion: @escaping () -> Void) {
        stopping = true
        pending = []
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    func readNow() -> HeadsetStatus {
        let fallback = readFallback()
        if fallback.connection == .dongle { return fallback }
        return resolve(dongleRead(), fallback: fallback)
    }

    private func resolve(_ reading: BarracudaX2022Reading?, fallback: HeadsetStatus) -> HeadsetStatus {
        guard let reading else { return fallback }
        if fallback.connection == .dongle ||
            (reading.connected != true && fallback.isConnected && fallback.connection == .bluetooth) {
            var status = fallback
            // Another connection must not hide a failed 2022 route cleanup.
            status.diagnosticMessage = reading.error ?? status.diagnosticMessage
            return status
        }
        return reading.status(audioActive: fallback.audioActive)
    }

    private func readFallback() -> HeadsetStatus {
        if let fallbackRead { return fallbackRead() }
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

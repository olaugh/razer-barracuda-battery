import Foundation
import CoreAudio

/// Watches the macOS default audio output device and reports whether the
/// Barracuda is currently the primary output.
final class AudioMonitor {

    private var onChange: (() -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listeningAddress: AudioObjectPropertyAddress?

    /// Start listening for default-output-device changes. `onChange` fires on
    /// the main queue whenever the default output switches.
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        listenerBlock = block
        listeningAddress = address
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    func stop() {
        guard let block = listenerBlock, var address = listeningAddress else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listenerBlock = nil
    }

    /// True if the current default output device name matches the Barracuda.
    func isRazerActive() -> Bool {
        guard let name = currentOutputDeviceName() else { return false }
        return name.localizedCaseInsensitiveContains("barracuda") ||
               name.localizedCaseInsensitiveContains("razer")
    }

    func currentOutputDeviceName() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        return deviceName(deviceID)
    }

    // MARK: - CoreAudio queries

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }
}

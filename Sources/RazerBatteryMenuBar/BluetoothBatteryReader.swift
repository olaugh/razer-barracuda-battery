import Foundation
import IOKit

/// Bluetooth fallback: when the headset is paired over Bluetooth (not the
/// dongle), macOS surfaces its battery via an `AppleDeviceManagementHIDEventService`
/// node carrying a `BatteryPercent` property.
final class BluetoothBatteryReader {

    /// Returns whether a matching Bluetooth headset was found and, if so, its
    /// battery percentage (0...100, nil if the property was absent).
    func read() -> (present: Bool, battery: Int?) {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return (false, nil)
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let name = stringProperty(service, "Product")
                ?? stringProperty(service, "DeviceName")
                ?? stringProperty(service, "BluetoothDeviceName")
            guard let name, isRazerHeadset(name) else { continue }
            let pct = intProperty(service, "BatteryPercent")
            return (true, pct)
        }
        return (false, nil)
    }

    private func isRazerHeadset(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("barracuda") ||
        name.localizedCaseInsensitiveContains("razer")
    }

    // MARK: - IORegistry property helpers

    private func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) else { return nil }
        return value as? String
    }

    private func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else { return nil }
        return (value as? NSNumber)?.intValue
    }
}

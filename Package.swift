// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RazerBatteryMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "RazerBatteryMenuBar",
            path: "Sources/RazerBatteryMenuBar",
            swiftSettings: [
                // Keep Swift 5 semantics: the IOKit/CoreAudio C callbacks and
                // the AppKit main-thread globals predate strict concurrency.
                .unsafeFlags(["-swift-version", "5"])
            ]
        )
    ]
)

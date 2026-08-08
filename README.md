# RazerBatteryMenuBar

A native macOS menu-bar app that shows the battery level and charging status of
the **Razer Barracuda X Chroma** headset, next to the system Sound icon.

```
🎧 85%        idle
🎧 85% ⚡     charging
🎧 —          not connected
```

## Features

- **Menu-bar status** (`NSStatusItem`) with inline text that adapts to light/dark menu bars.
- **Dual-mode battery monitoring**
  - **2.4 GHz dongle**: reads battery + charging from the headset's asynchronous
    HID input-report broadcasts over IOKit / `IOHIDManager` (VID `0x1532`, PID `0x0574`,
    control interface on usage page `0xFF13`). See the protocol notes below.
  - **Bluetooth**: falls back to IORegistry `AppleDeviceManagementHIDEventService` → `BatteryPercent`.
- **CoreAudio integration**: listens for default-output-device changes
  (`AudioObjectAddPropertyListenerBlock`) and shows whether the Barracuda is the active output.
- **Event-driven**: no busy polling — the listener wakes only when the headset
  broadcasts (plug/unplug, or a battery update ~every 10 min), so idle CPU ≈ 0.
- **Dropdown**: Battery %, charging state, connection type, audio-active status,
  Launch at Login (`SMAppService.mainApp`), Quit.

## Build & install

```sh
make install          # build + bundle + install to ~/Applications
open ~/Applications/RazerBatteryMenuBar.app
```

Other targets:

```sh
make build            # just build the binary (.build/release/RazerBatteryMenuBar)
make run              # run in the foreground
make once             # print current status once and exit
make probe            # dump HID feature reports (protocol calibration, see below)
make list             # list all HID devices + report sizes
```

On a healthy toolchain, `swift build -c release` works directly. `scripts/build.sh`
prefers SwiftPM and falls back to compiling with `swiftc` when SwiftPM is unavailable.

## The HID battery protocol (reverse-engineered)

The Barracuda X Chroma is MediaTek-based and does **not** use OpenRazer's classic
90-byte command report; its battery protocol is undocumented. It was reverse-engineered
live against the headset. The device **broadcasts** a 63-byte input report (id `0x02`,
`0xFF14` collection) whenever state changes, structured as a TLV record:

```
02 0a 60 CC 00 00 05 00 80 80 [KEY] 02 01 [VAL] 00 …
   header    ^byte3=seq         ^byte10   ^byte13
```

- `byte[10]` **selects the record**, `byte[13]` is its value:
  - `0x21` → **battery %** (e.g. `0x5c` = 92)
  - `0x2a` → **charging** (`0x01` charging / `0x00` not)
  - `0x13` → power-event (unused)
- `byte[2]` = `0x60` is a constant **header** byte, *not* battery.
- `byte[3]` is a broadcast **sequence counter** — ignored.

Because battery only rides these async broadcasts (the 8-byte feature report stops
before `byte[13]`), `HIDStateListener` keeps the device open, listens via
`IOHIDDeviceRegisterInputReportCallback`, demuxes by `byte[10]`, and caches each value
(persisting battery so the menu bar isn't blank on launch).

### Diagnostics

```sh
make monitor             # live GUI: polls + highlights changed bytes + decodes broadcasts
make probe               # dump the report descriptor + feature sweeps
make once                # print current status once
# also: --snapshot, --watch, --listen, --list-devices
```

The `--monitor` window is the tool used to crack the protocol: it shows each broadcast
decoded (`key=0x.. val=0x.. → battery N% / charging`) with changed bytes highlighted.
If a firmware update shifts the offsets, adjust the `key*/*Offset` constants in
`Sources/RazerBatteryMenuBar/RazerProtocol.swift`.

## Layout

```
Package.swift                              SwiftPM manifest (macOS 13+)
Makefile                                   build / run / probe / monitor / install
scripts/build.sh                           SwiftPM build with swiftc fallback
scripts/install.sh                         assemble .app bundle + install
Resources/Info.plist                       bundle metadata (LSUIElement, bundle id)
Sources/RazerBatteryMenuBar/
  main.swift                               entry point + CLI subcommands
  AppDelegate.swift                        NSStatusItem + dropdown menu + refresh loop
  BatteryMonitor.swift                     aggregates dongle + Bluetooth + audio
  HIDStateListener.swift                   async HID broadcast listener + TLV demux
  HIDBatteryReader.swift                   IOKit device lookup + report I/O helpers
  HIDProbe.swift                           --probe / --snapshot / --watch / --listen
  MonitorWindow.swift                      --monitor live GUI diagnostic window
  RazerProtocol.swift                      device constants + record key/offsets
  BluetoothBatteryReader.swift             IORegistry BatteryPercent fallback
  AudioMonitor.swift                       CoreAudio default-output listener
  LoginItem.swift                          SMAppService launch-at-login wrapper
  StatusFormatter.swift                    menu-bar + dropdown strings
  Models.swift                             HeadsetStatus / ConnectionType
```

# RazerBatteryMenuBar

A native macOS menu-bar app that shows the battery level and charging status of
the **Razer Barracuda X (2022)** and **Razer Barracuda X Chroma** headsets,
next to the system Sound icon.

```
🎧 85%        idle
🎧 85% ⚡     charging
🎧 —          not connected
🎧 ?          connection unknown
```

## Features

- **Menu-bar status** (`NSStatusItem`) with inline text that adapts to light/dark menu bars.
- **Dual-mode battery monitoring**
  - **2022 2.4 GHz dongle** (`1532:0552`, usage page `0xFF00`): queries battery
    and charging-cable presence using the PA/PI protocol. Runs off the UI thread
    on startup, every 60 seconds, and when the menu opens. See protocol notes below.
  - **Chroma 2.4 GHz dongle**: reads battery + charging from the headset's asynchronous
    HID input-report broadcasts over IOKit / `IOHIDManager` (VID `0x1532`, PID `0x0574`,
    control interface on usage page `0xFF13`). See the protocol notes below.
  - **Bluetooth**: falls back to IORegistry `AppleDeviceManagementHIDEventService` → `BatteryPercent`.
- **CoreAudio integration**: listens for default-output-device changes
  (`AudioObjectAddPropertyListenerBlock`) and shows whether the Barracuda is the active output.
- **Chroma is event-driven**: no busy polling — the listener wakes only when the headset
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
swift test            # protocol, cleanup, and refresh regression tests (no hardware needed)
# Optional live test: powered-on 2022 headset + its dongle required.
RAZER_HARDWARE_TEST=1 swift test --filter BarracudaX2022HardwareTests.testBackgroundHardwareReadWhenRequested
```

On a healthy toolchain, `swift build -c release` works directly. `scripts/build.sh`
prefers SwiftPM and falls back to compiling with `swiftc` when SwiftPM is unavailable.

## Barracuda X (2022) dongle protocol

The 2022 model is **not** protocol-compatible with Chroma. Its Macronix dongle
(`1532:0552`) exposes vendor report ID `1`, with 63-byte input/output payloads
(64 bytes including the report ID). Report ID `2` carries media controls.

`BarracudaX2022Session` performs a serialized, bounded transaction:

1. Read `E3` to confirm the wireless link; USB presence alone is insufficient.
2. Check existing headset transport (`E6` bit `0x08`) and local route (`E0=00`).
3. Select remote diagnostics (`E1 01`) and verify `E0=01`.
4. Send family-8 GETs `21 00 00` (battery) and `2a 00 00` (cable).
5. After any remote-selection attempt, restore `E1 00` and verify `E0=00`,
   retrying cleanup once if necessary.

Host reports have the form `01 80 LEN 50 41 FAMILY SEQ PAYLOAD_LEN PAYLOAD…`,
zero-padded to 64 bytes. Device PI frames are reassembled across tunnel chunks;
route/link responses are accepted only after the matching sequence ACK.
Battery replies contain `21 01 01 VV`, where `VV` is a direct 0–100 percentage.
Cable replies contain `2a 01 01 VV` (`00` absent / `01` present).
The UI presents cable presence as charging; it does **not** establish charge
current, completed charging, or the headset's LED state.

Battery/cable queries and local-route restoration have been validated on a
2022 headset on macOS. Failed telemetry stays unknown, never 0%.
A failed wireless-link query is shown as unknown rather than disconnected.
No Chroma battery cache is reused for this model.

Normal app quit waits for transaction cleanup. Do not force-quit during a query
or run unrelated HID tools concurrently. A per-user lock coordinates this app's
GUI and `--once` instances, but cannot lock out third-party software. If route
restoration fails, the menu/CLI reports an error; replug the dongle before retrying.
Queries refuse to select remote diagnostics if the route is already non-local.
No pairing, settings, firmware, or radio-transport creation commands are sent.

Use `make once` to read the 2022 model. `--probe`, `--snapshot`, `--watch`,
`--listen`, and `--monitor` remain **Chroma-only diagnostics**; they do not probe
the 2022 dongle. Chroma takes priority if both models' dongles are connected.

Protocol reference: [leag/razer-barracuda](https://github.com/leag/razer-barracuda/blob/main/docs/PROTOCOL.md).
No Linux driver or Python dependency is needed on macOS.

## Chroma HID battery protocol (reverse-engineered)

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
  BarracudaX2022Protocol.swift              safe PA/PI commands, decoder, routed query session
  BarracudaX2022Reader.swift                2022 IOKit transport + per-user query lock
  HIDProbe.swift                           --probe / --snapshot / --watch / --listen
  MonitorWindow.swift                      --monitor live GUI diagnostic window
  RazerProtocol.swift                      device constants + record key/offsets
  BluetoothBatteryReader.swift             IORegistry BatteryPercent fallback
  AudioMonitor.swift                       CoreAudio default-output listener
  LoginItem.swift                          SMAppService launch-at-login wrapper
  StatusFormatter.swift                    menu-bar + dropdown strings
  Models.swift                             HeadsetStatus / ConnectionType
```

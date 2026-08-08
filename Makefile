BINARY := .build/release/RazerBatteryMenuBar

.PHONY: build run probe list once login-status install clean

## Build the executable (SwiftPM, or swiftc fallback).
build:
	./scripts/build.sh

## Run the menu-bar app in the foreground.
run: build
	$(BINARY)

## Open the live GUI HID monitor (diagnostics).
monitor: build
	$(BINARY) --monitor

## Dump HID feature reports to calibrate the battery protocol.
probe: build
	$(BINARY) --probe

## List all HID devices and their report sizes.
list: build
	$(BINARY) --list-devices

## Print current headset status once and exit.
once: build
	$(BINARY) --once

## Show launch-at-login status.
login-status: build
	$(BINARY) --login-status

## Build, bundle, and install to ~/Applications (PREFIX to override).
install:
	./scripts/install.sh

clean:
	rm -rf .build

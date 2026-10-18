# Wi-Fi driver sources

`src/` contains native chipset formats, hardware resource checks, country policy,
entropy, and the original station/security engine. It is a source library for
separately linked driver images and native protocol tests. Optional Wi-Fi
implementation code is not linked into normal kernel radio controls.

The first executable package lives in `../mt7922/`. It owns its boot preparation
and retained native station through Driver ABI 1.0. The kernel retains physical
allocation tickets and converts only copied ABI events into NetworkCore events.
See [driver packages](../../docs/driver-packages.md) for selection and staging.

The library also preserves bounded Intel and Realtek identification/format work;
that does not make those families operational packages. Current native hardware
setup remains the explicit x86 UEFI MT7922 port.

`tests/wifi_device_adapter.zig` is a test helper for the direct station binding.
Its tests verify revocation after a device epoch changes and terminal retirement
on disconnect. The production generic C ABI adapter and its tests remain under
`kernel/src/core/wifi_module_adapter{,_tests}.zig`, with no chipset imports.

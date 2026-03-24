# Columba

An iOS messaging app built on [Reticulum](https://reticulum.network) for encrypted, off-grid communication. Supports text messaging, voice calls, location sharing, and file transfers over TCP, local WiFi, BLE, and LoRa radio.

## Building

Requires Xcode 15+ and iOS 17+.

Open `ColumbaApp.xcodeproj` in Xcode, select a signing team, and build for your device.

Dependencies are resolved automatically via Swift Package Manager.

## Architecture

- **ReticulumSwift** — Core Reticulum protocol stack
- **LXMFSwift** — LXMF messaging layer
- **LXSTSwift** — Voice call transport
- **MapLibre** — Offline-capable map rendering

## Acknowledgements
- This work was partially funded by the [Solarkpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF) and [LXST](https://github.com/markqvist/LXST) by Mark Qvist

## License

[AGPL-3.0](LICENSE)

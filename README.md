# Columba

An iOS messaging app built on [Reticulum](https://reticulum.network) for encrypted, off-grid communication. Supports text messaging, voice calls, location sharing, and file transfers over TCP, local WiFi, BLE, and LoRa radio.

## Building

Requires Xcode 15+ and iOS 17+.

Open `Columba.xcodeproj` in Xcode, select a signing team, and build for
your device. SPM resolves all dependencies (LXMFSwift, LXSTSwift,
ReticulumSwift, MapLibre) automatically from their public GitHub
repositories on first open — no sibling clones required.

### Local development against unreleased library changes

To work against an in-progress local clone of any of the Reticulum-stack
libraries without committing a path-override, drop a per-machine SPM
mirror file at `.swiftpm/configuration/mirrors.json` (already gitignored
via `.swiftpm/`):

```json
{
  "version": 1,
  "object": [
    { "original": "https://github.com/torlando-tech/reticulum-swift.git", "mirror": "/Users/you/repos/reticulum-swift" },
    { "original": "https://github.com/torlando-tech/LXMF-swift.git",      "mirror": "/Users/you/repos/LXMF-swift"      },
    { "original": "https://github.com/torlando-tech/LXST-swift.git",      "mirror": "/Users/you/repos/LXST-swift"      }
  ]
}
```

The top-level key is `object`, not `mirrors`. That's the on-disk
format SPM's `MirrorsStorage` reads, the same shape that
`swift package config set-mirror` writes — using `mirrors` results
in a no-op load with no warning.

SPM transparently resolves the listed URLs to your local checkouts, so
you can iterate on a library and the iOS build picks up the changes
without modifying `Package.swift` or the Xcode project. Remove the file
to go back to the published versions.

## Architecture

- **ReticulumSwift** — Core Reticulum protocol stack
- **LXMFSwift** — LXMF messaging layer
- **LXSTSwift** — Voice call transport
- **MapLibre** — Offline-capable map rendering

## Acknowledgements
- This work was partially funded by the [Solarpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF) and [LXST](https://github.com/markqvist/LXST) by Mark Qvist

## License

[AGPL-3.0](LICENSE)

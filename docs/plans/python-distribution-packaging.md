# Python distribution packaging

## Failure evidence

The rejected distribution export selected **Apple Distribution: Torlando Tech LLC** for both the app and extension, with the same team. The original device archive and exported app both pass `codesign --verify --deep --strict`. All 2,014 Python/script resources in each host have matching hashes in their resource signature manifests.

App Store rejected 1,961 files under `PlugIns/ColumbaNetworkExtension.appex`, including Python sources, type stubs, script fixtures, and command-line entry points. Their content is classified as executable scripts by `file`, even when permissions are `0644`. Identical app-level copies are not reported. This is a distribution layout problem; re-signing the extension again does not change that layout.

[Apple's bundle layout guidance](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle) treats scripts as resources and places iOS frameworks at the top application level, rather than inside an extension.

## Change

The application now packages Python once: `app/`, `app_packages/`, `python/`, and the native frameworks in its top-level `Frameworks/` directory. The extension still runs its own interpreter and Reticulum node, but reads this immutable payload from its containing application. Its existing `@executable_path/../../Frameworks` runpath resolves Python.framework.

`NodePythonBundleLayout` resolves the same resource bundle for either host. Python's configured executable is anchored to that bundle's executable before initialization because [CPython's AppleFrameworkLoader](https://github.com/python/cpython/blob/3.13/Lib/importlib/_bootstrap_external.py) resolves `.fwork` and `.origin` paths relative to `sys.executable`. This setting does not launch the UI app or change which process supplies native callback symbols.

The extension's duplicated installation/signing phase is replaced with scoped cleanup of obsolete generated payloads, including incremental builds. Python source deployment for BLE/RNode uses the app's sole payload. Target signing settings remain automatic.

The unified artifact verifier rejects extension-local Python payloads, stray Python modules, and nested frameworks. Xcode Cloud's post-archive hook checks signatures and this distribution layout before export.

## Validation

- The new layout check rejects the actual failed distribution export.
- All 259 tests in the static CI lane pass, including executable Swift host-layout contracts.
- Seven project tests pass with 313 assertions, including reconciliation idempotence and cleanup restricted to the generated extension product.
- Simulator Debug and stripped Release builds pass. Both artifacts pass the unified artifact verifier.
- The stripped extension contains zero files classified as executable scripts. Both process hosts retain every native callback in the C ABI export manifest.
- Simulator startup initializes Python 3.13.11 and the Reticulum node using the shared payload. Its configured test TCP listener is unavailable, so this is startup/import validation, not a peer-delivery test.

A new device install must still confirm extension startup and BLE/RNode operation with the app-level payload. App Store validation of a newly signed/exported IPA remains required; local signature verification alone did not detect the original rejection. The local command-line development signing helper cannot access its private key, so physical-device validation was not claimed.

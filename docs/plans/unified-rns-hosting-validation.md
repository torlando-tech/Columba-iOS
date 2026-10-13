# Unified RNS hosting validation

The `refactor/unified-rns-hosting` worktree starts from main at `b023013b`. One application contains both adapters. `ProxyRnsBackend`, command dispatch, Python lifecycle, native radios, shared persistence, inbox/outbox recovery, field processing, and voice transport are common to both hosts. Background hosting remains the default. Settings saves a choice; a fresh app launch commits it, so a tunnel reconnect cannot prematurely apply a pending choice.

## Automated validation (2026-10-12)

- Signed Xcode 26.4.1 Debug app, extension, and hosted tests build successfully for iPhone.
- Signed Release builds with deployment postprocessing and stripping. The unified artifact verifier passes for Python resources, native exports, framework linkage, and app/extension entitlements.
- Local CI regression suite: 268 tests, zero failures, one skip.
- Project reconciliation: four tests, 295 assertions; source membership, one test host, adapter boundaries, and repeated reconciliation pass.
- Full iPhone hosted run: 606 tests; 604 pass, one fails, one skips. The failure is the unchanged `MicronParserTests.testNestedWrappedParagraphReservesBothSectionMargins` pixel assertion. The source-wiring inspection skips on physical devices because the Mac checkout is unavailable there; it remains runnable on the simulator host.
- Final host/drain stress run: all 16 targeted tests pass across ten iterations (160 executions), including observer release and restart ownership. Both stripped process hosts retain every native callback in the export manifest.
- A device run exposed an existing dangling Darwin observer when a started facade was released without `stop()`. The facade now unregisters on deinitialization, and a regression test exercises release followed by notification. The subsequent full run has no observer crash.
- Real foreground startup initializes Python in the application and reports connected TCP, AutoInterface, BLE, and RNode interfaces. A normal fresh launch restores the saved background mode, keeps the same identity/destination, and starts through the extension proxy without app-local Python initialization.

The app's BLE interface object is a UI mirror. Its teardown no longer stops `SwiftBLEBridge` directly; the shared Python engine owns the actual radio in either process. A regression contract protects this boundary.

## Remaining manual regression

Build and artifact validation do not replace an end-to-end messaging soak. Exercise both modes with existing identities and history:

- Text, image/file/audio attachments, reactions, replies, peer appearance, and location updates; confirm one inbound notification and one application of each field.
- Direct/opportunistic delivery, propagated fallback, sync/cancel, offline outbox recovery, and delivery proofs after reconnect.
- Voice setup, incoming calls, cancellation, and teardown.
- Interface edits and toggles, RNode reconnects, BLE peers, identity changes, and discovery settings. Confirm an AutoInterface-blocked same-process restart requests a relaunch.
- Save a hosting choice while connected, reconnect the current tunnel, then freshly launch. Confirm the choice takes effect only at launch and foreground mode disables this app's VPN on-demand.
- Suspend/terminate the UI during background delivery, then reopen and check bounded inbox catch-up and field replay. Run the extension overnight again to assess real memory and reconnection behavior.

## PR review follow-up

All four reported regressions were valid. Periodic retrieval now belongs to the shared Python node: it reads the saved relay/interval/enable settings in either host, runs bounded syncs, cancels on stop, and rejects cancelled workers after restart. Foreground retrieval pauses when iOS suspends the app; extension retrieval does not depend on a UI timer or opportunistic BGTask delivery. Discovery navigation/summaries use the common backend. Transport changes rewrite the config and restart through the shared lifecycle, with a notice when AutoInterface requires a fresh process. The screenshot install command no longer receives an artifact-verifier flag.

Follow-up validation: signed Debug app/extension/test build passes; all 42 focused scheduling, host, and drain tests pass on the iPhone; all 255 tests in the configured static CI lane pass. Four new wiring checks fail against the pre-fix commit and pass with the fixes. The schedule policy test covers deadlines, repeated checks, interval/relay changes, disabling/re-enabling, and clearing selection. An actual relay retrieval while the UI is suspended remains part of manual regression.

### Relay-selection race and completion history

Scheduled retrieval no longer reapplies its saved relay snapshot. Python's live selection remains owned by selection commands, so a timer cannot undo a clear or replacement while its preference save is pending. Startup still restores the saved relay once when bringing the node up.

Both manual and scheduled sync now publish confirmed success through the shared completion snapshot and existing last-sync preference. Failed or missing replies leave history unchanged. Settings refreshes on completion notification, appearance, and app activation; app activation also refreshes the manager before deciding whether to retrieve again. Preference saves no longer write a potentially stale cached completion time.

The signed Debug app, extension, and hosted tests build successfully. All 256 static CI tests pass; the updated wiring checks fail against the pre-fix commit. Added device regressions exercise persisted completion times/counts, fresh-manager catch-up, unsuccessful replies preserving history, successful zero-message retrieval, and legacy snapshot decoding.

All 44 focused scheduling/history, host, and drain tests pass on the physical iPhone after this follow-up. End-to-end relay retrieval with the UI suspended remains on the manual checklist.

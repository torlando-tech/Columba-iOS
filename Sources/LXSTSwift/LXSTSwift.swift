// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
// reticulum-swift was deleted in Phase 0 of the Python RNS migration.
// LXSTSwift's old `@_exported import ReticulumSwift` now points at
// RNSAPI's Compat layer instead — the protocol primitives lxst-swift
// uses (Identity, Destination, Packet, etc.) are still imported via
// `import RNSAPI` from each source file. Link operations underneath
// delegate to PythonRNSBackend (the embedded canonical Python RNS).
@_exported import RNSAPI

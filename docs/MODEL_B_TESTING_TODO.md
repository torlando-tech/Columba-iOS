# Model B product — on-device test plan (next steps)

Historical Model B work verified inbound LXMF delivery, announce paths, and the
relay TCP path on a physical device. Those historical results are orientation,
not release evidence for the compile-isolated product branch; perform the fresh
physical-device checks below before claiming device support. The remaining hard
surface includes radios, delivery while locked, and the memory GATE.

> Before any test below, build the explicit `ColumbaModelBApp` target through the
> shared `Columba-ModelB` scheme. Runtime architecture is compile-time isolated;
> persisted settings never switch the shipping Python product into Model B.
> Confirm operation through Settings → Network Status and the NE relay card.
>
> Peer for all tests = the **Android Columba** client ("Torlando - Columba",
> lxmf.delivery dest `<peer-dest>…`). Relay = the LAN Reticulum host (`lxmd`/`rnsd`).

---

## 1. Radio bridging (app bridges BLE / RNode → NE-owned node)

Model B's app process owns **no destination**; it pumps radio frames to the
NE over the App-Group bridge, and the NE-owned node terminates delivery. These
tests prove that bridge in both directions.

- [ ] **BLE inbound:** pair the device with a BLE Reticulum peer (RNode/again the
      Android client over BLE, **TCP relay disabled** so the only path is BLE).
      Peer announces → appears in Contacts → Network tab. Peer sends an LXMF
      message → message renders + a delivery proof goes back. Confirms
      app→bridge→NE inbound + NE→bridge→app→radio proof egress.
- [ ] **BLE announce egress:** tap the announce button → confirm the NE's
      self-announce reaches the BLE peer (peer sees us). Check `ext-diag.log`
      for `announce EMITTED … ifaces=[…ble…]`.
- [ ] **RNode (best-effort):** same two checks over an RNode interface. RNode-on-
      iOS is immature — treat failures as "scope note", not a Model B regression.
- [ ] **Dual-path dedup:** peer reachable over **both** TCP relay and BLE at once;
      send one message → exactly **one** row + **one** banner (NE-side dedup).
- [ ] **MTU sanity:** send a multi-part message over BLE (small attachment) →
      confirm the NE never forms a link the radio MTU can't carry (no stalled
      transfer). Watch for resource-cancel in `ext-diag.log`.

> Note (known scope gap): the native BLE/RNode path belongs to the Model B
> product; the legacy driver path was Python-coupled. If BLE delivery does not
> work in Model B yet, that is the documented C8 follow-on, not this bug.

---

## 2. Delivery while locked / backgrounded (the headline feature)

The NE must complete delivery and post the notification **itself** while the host
app is suspended and the phone is locked (a suspended app can't be woken — Apple
DTS 769398).

- [ ] **Locked opportunistic (headline):** unlock once since boot, then **lock**
      the device, leave it ~30s (app suspended, NE alive). Peer sends an
      opportunistic LXMF message → a **rich** banner (sender name + preview) on
      the lock screen. Unlock → message already in the thread, no re-fetch.
- [ ] **Locked direct + attachment:** locked, peer sends a direct message with a
      small image → NE completes the Link + reassembly while locked, persists,
      notifies. Then a **large** attachment (exercises Track L disk-streaming).
- [ ] **Backgrounded (not locked):** app backgrounded (home screen), peer sends →
      banner + thread updates on next foreground.
- [ ] **Jetsam recovery:** background the app, force-kill the NE under memory
      pressure (or `devicectl … process terminate` the NE pid) → the on-demand
      rule relaunches the tunnel → next message still delivers.
- [ ] **Restart identity invariance:** note the delivery dest (`<delivery-dest>…`), kill +
      relaunch the NE, confirm the **same** dest + intact history (shared identity
      + shared store ⇒ transparent restart).
- [ ] **Proof timing:** confirm the sender (Android) shows "delivered" (our proof
      arrived) for each locked delivery — no send-side timeout.

Capture lock-screen behavior with a photo/video (no unified-log over WiFi). Pull
the NE log after each run: `devicectl … appDataContainer … Documents/ext-diag.log`.

---

## 3. Under-pressure / NE memory GATE (Phase 1b)

**Goal:** prove the NE survives the realistic delivery **peak** without a
memory-reason jetsam kill — the single assumption the whole epic rests on. The
old PoC only measured *idle* (~13.8 MB). This measures *under load*.

**Why it felt hard:** there's no Xcode memory gauge over WiFi and the NE is a
separate, hard-to-attach process. The trick is to make the **NE log its own
memory** and drive load from a desktop peer — no debugger needed.

### 3a. Instrument — DONE (shipped as `NEMemoryTrace`)

The NE samples itself into a fixed 8192-slot ring in the App-Group container
(`ne-memory.bin`), charted in the app at **Settings → Reticulum Hosting → Memory
Usage**. Four claims in the original plan were wrong; each is verified against the
iOS SDK or Apple's docs, and each one would have produced a confident-but-false
verdict:

- [x] The kill metric is `task_vm_info.phys_footprint`, **not**
      `mach_task_basic_info().resident_size`. The kernel enforces
      `memorystatus: … ActiveHard <N> MB` on footprint; RSS also counts shared
      file-backed pages, so an RSS number is not comparable to the ceiling.
- [x] `os_proc_available_memory()` cannot serve as the ceiling probe: it returns
      `0` for any process that "isn't an app", which an app extension may be, so
      `0` can never be read as "at the limit". The trace records
      `task_vm_info.limit_bytes_remaining` and treats `0` as *unknown*.
- [x] There is **no `NEProviderStopReason.memoryLow` case** — the enum has no
      memory reason at all — and a memory kill is a bare SIGKILL with no
      `stopTunnel` callback. A kill is detected as a process generation (pid)
      whose records end with **no `.stop` marker**; `stopTunnel` still writes the
      reason for every teardown iOS does announce.
- [x] No `measureRNSFootprint()` sampler has ever existed in this repo's history
      (`git grep` across every revision finds nothing). `NEMemoryTrace` is new.
- [x] The sampler runs on a **detached native `Thread`**, not a `Task` or a
      run-loop `Timer`: the NE's main dispatch thread is blocked during bring-up
      and announce floods, so a cooperative sampler records nothing and looks
      exactly like a process that never grew.

### 3b. Drive load (desktop peer over the relay)
- [ ] **Small/opportunistic burst:** desktop peer sends N opportunistic messages
      back-to-back to our dest → sample peak resident across the prove+persist window.
- [ ] **Small Link/Resource:** peer sends a small direct (Link) message → sample
      across link setup + reassembly.
- [ ] **Large attachment:** peer sends a 24–32 MB **incompressible** attachment
      (`autoCompress:false`) → this is the real stressor; it exercises Track L
      disk-streaming. Sample the whole transfer.
- [ ] Run each scenario **5×** to catch variance.

### 3c. Verdict (iPhone 14)
- [ ] **PASS:** peak `phys_footprint` (Memory Usage screen, or the
      `ne-memory.bin` ring) stays **≥ 8 MB below** the ceiling this device
      actually enforces — read that number from `idevicesyslog`
      (`memorystatus: … ActiveHard <N> MB`), never from
      `os_proc_available_memory()`, which may report 0 regardless — across all 5
      runs, and **zero** generations end without a stop marker → Model B holds
      for that payload class.
- [ ] **CONDITIONAL:** small fits but the large attachment breaches → ship small-
      payload delivery now; large-payload delivery gated on finishing Track L
      streaming (L2/L3 landed; verify the peak is window-bounded, not payload-bounded).
- [ ] **FAIL:** even a small Resource gets jetsam-killed → escalate; fall back to
      sniff-only + complete-on-open and re-scope.

> Shortcut now that delivery actually works: you can get a first read **without**
> the harness — drive real traffic from the Android peer, then open
> **Settings → Reticulum Hosting → Memory Usage** (or pull
> `…/AppGroup/ne-memory.bin` and decode it). The controlled desktop-peer harness
> is only needed for the clean 5-run numbers in the verdict.

---

## 4. Known-open / deferred (track, not blockers for the above)

- [ ] **Incoming-message render bug (Network-tab path)** — under diagnosis. This
      build adds `[DIAG-STORE]` (app's read view at launch) + `[MSG] … records=/loaded=`
      logs. Repro: open the convo via Contacts→Network tab (empty) and via Chats
      (works), then pull `diag.log` and compare the two `[MSG]` lines' counts vs the
      `[DIAG-STORE]` count. **Remove these temp DIAG logs once root-caused.**
- [ ] **Conversation display name** — fixed this build: an announce carrying a name
      now stamps it onto an existing nil-name conversation. Verify the convo title
      flips from the "Peer <hash>" fallback to the announced name after the peer re-announces
      (≈ every few min) + re-opening the thread.
- [ ] **A5 read-path follow-up** — the app still opens the shared store
      `readonly: false` (it should be `readonly: true`, NE = sole writer; see
      `MessageRepository.swift` A5 note). Decide after the render-bug diagnosis,
      since it interacts with the read path.
- [ ] **`bypassTunnelEgress` revert-candidate** — reticulum-swift PR #18 added it as
      defensive insurance; the real egress fix was bouncing the wedged relay daemon.
      Revisit / consider reverting once egress has been stable for a while.

---

## Tooling cheatsheet

- Device: iPhone 14, devicectl id `<device-id>`. Get the
  **current LAN IP** from the NE socket / `lsof`, not memory (DHCP moves it).
- Pull NE log: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier network.columba.Columba --source Documents/ext-diag.log --destination /tmp/ext-diag.log`
- Pull app log: same, `--source Documents/diag.log`.
- The shared **GRDB DB** can't be pulled live (devicectl `..` bug + the NE holds it
  open). Use the in-app `[DIAG-STORE]` log instead, or copy the DB to Documents
  from app code if raw rows are needed.
- Relay bounce (clears a wedged daemon): `launchctl kickstart -k gui/$(id -u)/network.reticulum.rnsd` and `…/network.lxmf.lxmd`.
- Build and test with the shared `Columba-ModelB` scheme. The **Build** action
  owns `ColumbaModelBApp` and `ColumbaNetworkExtension`; the **Test** action owns
  `ColumbaModelBAppTests`. Use `build-for-testing` or the Test action when all
  three products must compile together. **Verify the host, tests, and extension
  together** — an app-only build is a false green for Network Extension changes.

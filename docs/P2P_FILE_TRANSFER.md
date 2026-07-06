# Notilus P2P File Transfer — Implementation Plan

> AirDrop-style, machine-to-machine file transfer over the internet.
> **Direct peer-to-peer** (WebRTC DataChannel) so file bytes never touch a
> server → **zero bandwidth cost**. A free Firebase **Realtime Database** tier
> is used only for tiny signaling/presence messages (kilobytes).

**Status:** ✅ Phases 0–9 code complete · 🟣 Phase 10 = hands-on live verification (runbook ready, awaiting two-machine runs) · Last updated: 2026-07-06

**Workflow:** one phase at a time — implement a phase, stop, wait for "next".

---

## Progress legend
- `- [ ]` todo · `- [x]` done · `- [~]` in progress / partial
When you finish a task, tick its box and bump the phase status + "Last updated"
so the next session can resume without re-reading everything.

**Resume pointer:** _(update each session)_ → **Phase 10 — hands-on live
verification.** All code is done; the code-side aids for testing are in place
(WebRTC diagnostics + UI now shows Connecting/Failed, not a silent hang). Follow
**`docs/P2P_TESTING.md`** on two machines and tick the checklist there. Optional
code polish still open: (a) fuller RTDB orphan-sweep for offer/ICE (only the
request is swept today), and (b) a native "Browse…" folder picker
(`file_selector`) to replace the typed destination path.

---

## Locked decisions
- **Transport:** WebRTC DataChannel, **direct only** (STUN-assisted). **No TURN**
  relay (option A) — transfers on doubly-symmetric-NAT networks simply fail with
  a clear message. Keep a config slot to add TURN later.
- **Signaling / presence backend:** Firebase **Realtime Database**, accessed via
  **REST + Server-Sent-Events** (NOT the FlutterFire plugins, which have no Linux
  support). Keeps macOS/Windows/Linux builds all working.
- **Pairing:** persistent identity. Each install has a stable `deviceId` +
  keypair. Friends are exchanged **once** (QR / copy-paste) and saved in a local
  contacts list by name. No per-transfer codes.
- **Trust:** send to saved contacts; verify sender via their saved public key,
  reject unknown senders. WebRTC is DTLS-encrypted in transit.
- **Cost:** free. RTDB Spark tier (signaling only) + free public STUN + users'
  own bandwidth for the data.

## Non-goals (for now)
- TURN relay / guaranteed connectivity on hostile NAT.
- OS push to a fully-quit app (recipient must have Notilus running, incl. tray).
- Mobile targets (desktop-first).

---

## Architecture at a glance

```
Alice (Notilus)                 Firebase RTDB (free)                 Bob (Notilus)
   |                             [signaling mailbox only]                |
   |-- write transfer-request -> /users/{bob}/inbox --- SSE push ------->|  (dialog: accept/decline)
   |<-------------------------- /users/{alice}/inbox <-- accept ---------|
   |-- offer + ICE ------------> /users/{bob}/inbox --------------------->|
   |<------------------------ answer + ICE <-- /users/{alice}/inbox ------|
   |                                                                      |
   |==================  DIRECT WebRTC DataChannel  ======================|
   |=====================  file bytes, no server  ======================>|
```

### RTDB data model
```
/users/{deviceId}/
    profile/            { name, publicKey, lastSeen }     # lastSeen = heartbeat presence
    inbox/{msgId}       { type, from, ts, payload }        # consumed then deleted
```
`msg.type ∈ { transfer-request, transfer-response, webrtc-offer, webrtc-answer,
ice-candidate, cancel }`.

### Signaling sequence
1. Alice → `transfer-request` into Bob's inbox `{ files:[{name,size}], count }`.
2. Bob's SSE stream fires → **"Alice wants to send N files — Accept / Decline."**
3. Bob → `transfer-response` `{ accepted: true|false }` into Alice's inbox.
4. On accept, Alice (offerer): `createOffer` → `webrtc-offer`; trickle `ice-candidate`s.
5. Bob: setRemote → `createAnswer` → `webrtc-answer`; trickle `ice-candidate`s.
6. DataChannel opens → transfer. Inbox messages deleted once consumed.

### File protocol (over DataChannel)
- Per file: JSON header `{name, size, index, total, sha256}` → binary chunks
  (~16 KB) → `file-done`. Then `batch-done`.
- **Backpressure:** watch `bufferedAmount` / `bufferedAmountLowThreshold`; pause
  reads when the send buffer is full.
- Receiver streams chunks to disk (`IOSink`), verifies sha256, then commits.

---

## Candidate packages (confirm versions in Phase 0)
- `flutter_webrtc` — peer connection + data channels (macOS/Windows/Linux ✅)
- `http` — RTDB REST calls
- `uuid` — deviceId / message ids
- `crypto` — sha256 integrity
- `cryptography` (or `pointycastle`) — keypair + signatures (sender auth)
- `qr_flutter` — render contact QR; add-contact also supports copy-paste
- `tray_manager` + `window_manager` — run-in-tray so the app can receive
- `flutter_local_notifications` — desktop notification on incoming request
  _(fallback: in-app dialog only)_

---

# Phases & tasks

## Phase 0 — Project & backend setup  ✅ DONE (verified 2026-07-05)
- [x] **(User)** Create a free Firebase project; enable **Realtime Database**.
- [x] **(User)** Enable **Anonymous** sign-in (Auth → Sign-in method).
- [x] **(User)** Paste your RTDB URL + Web API key into
      `lib/config/transfer_config.dart`.
- [x] **(User)** Publish the rules from `docs/rtdb.rules.json` in the RTDB console.
- [x] Verified end-to-end via REST: anon sign-in ✓, authed self-profile
      write/read ✓, cross-profile write denied ✓, inbox POST allowed ✓.
- [x] RTDB security rules written → `docs/rtdb.rules.json` (profile world-readable,
      owner-writable; inbox owner-read, any-authed-write).
- [x] Config strategy: git-ignored `lib/config/transfer_config.dart` +
      committed `transfer_config.example.dart`; `.gitignore` updated.
      (Move to GitHub secrets later.)
- [x] Foundational package added (`uuid`). Heavier/native packages
      (`flutter_webrtc`, `tray_manager`, …) are added in the phase that first
      needs them, to keep each phase self-contained.

## Phase 1 — Identity & local storage  ✅ DONE (2026-07-05)
- [x] Ed25519 signing keypair, generated on first run & persisted (seed in prefs);
      stable across restarts. → `IdentityService`
- [x] `deviceId` = Firebase uid; nullable until Phase 2 sets it via
      `setDeviceId(...)`; persisted so it stays stable for friends.
- [x] `IdentityService` (`lib/services/transfer/identity_service.dart`):
      keypair, display name (defaults to hostname), `sign`/`verify`,
      `asShareableContact()`.
- [x] `Contact` model (`lib/models/transfer/contact.dart`) with QR/paste
      `toShareCode()` / `fromShareCode()`.
- [x] `ContactsStore` (`lib/services/transfer/contacts_store.dart`):
      upsert/dedup-by-id, rename, remove, `isTrusted(id, pubkey)`, JSON persist,
      `ChangeNotifier`.
- [x] Unit tests (`test/transfer_identity_test.dart`) — 8 passing: keypair
      persistence, sign/verify + tamper/wrong-key rejection, share-code
      round-trip, store dedup/persist/trust/rename/remove.
- Added package: `cryptography ^2.9.0`.

**Note for Phase 2:** sign in anonymously ONCE, persist the refresh token, and
reuse it on later launches (refresh the idToken) so the uid — and therefore our
`deviceId` — stays stable. Call `identity.setDeviceId(uid)` after sign-in.

## Phase 2 — Signaling transport (RTDB over REST)  ✅ DONE (verified live 2026-07-05)
- [x] `RtdbClient` (`rtdb_client.dart`): authed GET/PUT/PATCH/POST(push)/DELETE,
      `.json?auth=<idToken>`, error type on non-2xx.
- [x] `FirebaseAuthClient` (`firebase_auth_client.dart`): anonymous sign-in via
      Identity Toolkit REST; persists refresh token + uid; `validToken()`
      auto-refreshes ~1 min before expiry; falls back to fresh sign-up if the
      refresh token is rejected.
- [x] SSE inbox listener: `decodeSse` (`sse.dart`) + `SignalingService`
      streams `/users/{uid}/inbox` (`text/event-stream`), handles snapshot `/`,
      live `/<pushId>` puts, `keep-alive`, `auth_revoked`→reconnect.
- [x] Inbox helpers: `send(toId, msg)` (push), `deleteInboxMessage(id)`,
      auto-reconnect (2s) on drop/error.
- [x] Heartbeat: `profile/lastSeen` every 20s; `isOnline()` = lastSeen within 70s.
- [x] `InboxMessage` model + type constants (`inbox_message.dart`).
- [x] **KvStore refactor:** `KvStore` abstraction + `MemoryKvStore` (pure Dart)
      and `PrefsKvStore` (app). `IdentityService`/`ContactsStore` now take a
      `KvStore` — keeps the transfer services Flutter-free so they run under
      `dart run` with real network.
- [x] Unit tests (`transfer_sse_test.dart`, 4) + live smoke tool
      (`tool/transfer_smoke.dart`): `dart run` → sign-in, profile, SSE
      round-trip, presence, cleanup — **PASSED**.

**Findings / notes for later phases:**
- Rules grant `.write` on `profile` + `inbox` children only, NOT on the parent
  `/users/{uid}` node → you can't delete the whole node; delete children you own.
- The smoke tool uses `MemoryKvStore`, so each run makes a new anon auth user
  (harmless orphans in Firebase Auth). The real app uses `PrefsKvStore` → one
  stable account/uid.
- App wiring (Phase 9) must build `PrefsKvStore(prefs)` and share it across
  `IdentityService` + `ContactsStore`, and call `SignalingService.start()`.

## Phase 3 — Contacts & presence UI  ✅ DONE (verified live 2026-07-05)
- [x] `TransferController` (`lib/providers/transfer_controller.dart`): app-facing
      ChangeNotifier — self-inits (prefs→`PrefsKvStore`→identity→contacts→
      signaling.start), presence polling every 25s, add/rename/remove, name edit
      (republishes profile). Handles not-configured / error / loading states.
- [x] Provided in `app.dart` MultiProvider.
- [x] `CenterView.transfers` + routing in `home_screen` (`_centerBody`,
      `_centerTitle`) + sidebar entry "File Transfer".
- [x] `TransferScreen` (`lib/screens/transfer/transfer_screen.dart`):
      "This device" card (name + edit, QR of share code, copyable code),
      contacts list with online/offline dots, Add-contact dialog (paste code),
      rename/remove action sheet.
- [x] Added package: `qr_flutter ^4.1.0`.
- [x] Verified: app launches, signs in, publishes profile (confirmed via REST
      read of `/users/<uid>/profile`), heartbeat live.

**Note:** interactive UI (clicking through, scanning QR) is for you to eyeball;
the data path is proven. The "Send to…" action + transfer progress UI stay in
Phase 9. Two machines/accounts needed to see a contact flip online (Phase 4+).

## Phase 4 — Transfer request & consent flow  ✅ DONE (verified live 2026-07-05)
- [x] Signed messages: `signed_messages.dart` — Ed25519 sign/verify over a
      canonical form (`v1|type|from|to|ts|stableEncode(payload)`), with
      recursive key-sorted JSON so RTDB key reordering can't break verification.
      `InboxMessage` gained a `to` field (+ `withSignature`).
- [x] `sendTransferRequest(contact, files)` → signed `transfer-request` with a
      `requestId`, tracked in `_pending` with a 60s timeout → returns
      accepted/declined.
- [x] Receiver `_handleRequest`: rejects unless `from` is a saved contact AND
      signature verifies AND `to == me` (else drops silently); else queues an
      `IncomingTransferRequest`.
- [x] `respondToRequest(req, accept)` → signed `transfer-response`; both sides
      delete inbox messages after handling.
- [x] `TransferRequestGate` (wraps app) shows the Accept/Decline dialog over any
      screen; queues multiple requests.
- [x] Models: `TransferFileInfo`, `IncomingTransferRequest`.
- [x] Temp tester: contact action-sheet "Send files (test)" (demo request +
      waiting/result dialog) — replaced by real "Send to…" in Phase 9.
- [x] Unit tests (`transfer_signing_test.dart`, 5) — stableEncode, sign/verify,
      JSON-reorder survival, tamper/wrong-key/wrong-recipient/unsigned rejection.
- [x] Live two-peer smoke (`tool/transfer_consent_smoke.dart`): A→request,
      B verifies+accepts, A gets signed accept; forgery checks all reject —
      **PASSED**.

**Note for Phase 5:** on accept, the answerer (receiver) and offerer (sender)
kick off the WebRTC handshake — hook into `respondToRequest` (accept branch) and
`sendTransferRequest` (accepted branch).

## Phase 5 — WebRTC connection  🟢 CODE DONE (needs 2-machine test to confirm live)
- [x] `WebRtcSession` (`lib/services/transfer/webrtc_session.dart`):
      `RTCPeerConnection` with free Google STUN (no TURN), offerer/answerer
      roles, ordered `files` DataChannel.
- [x] Offer/answer + trickle ICE over the signed inbox (`sessionId` in payload);
      remote ICE candidates buffered until the remote description is set.
- [x] `onConnected` completes with the open DataChannel; 30s connect timeout;
      `WebRtcFailure` with a clear "no direct connection on this network"
      message on ICE/connection failure (the no-TURN dead end).
- [x] Controller wiring: `_startSession` (answerer created in `respondToRequest`
      before the accept; offerer created in `_handleResponse` on accept),
      `_handleRtcSignal` routes offer/answer/ice to the session, `_sendSignal`
      signs+sends, `_endSession` cleans up; sessions closed on dispose.
- [x] Added `flutter_webrtc ^1.5.2`; macOS pod builds; app launches (not
      sandboxed → STUN/UDP allowed) with signaling still live.

**⚠ Verification gap:** flutter_webrtc is native → can't be driven via `dart run`
or `flutter test`. The DataChannel actually opening is unverified until run on
**two machines**. To test now: add each other as contacts → contact ⋯ → "Send
files (test)" → Accept on the other side → watch debug logs for
`WebRTC connected: session=…` (or the no-path failure). File bytes are Phase 6.

## Phase 6 — File transfer protocol  🟢 CODE DONE (needs 2-machine test to confirm live)
- [x] Chunked sender with `bufferedAmount` backpressure; multi-file batches.
      → `FileSender` in `lib/services/transfer/file_transfer.dart` (16 KB chunks,
      1 MB high-water / 256 KB low-water, buffered-low event + poll fallback).
- [x] Receiver: streamed reassembly to disk (`IOSink` → `<name>.part`), per-file
      + overall progress (`BatchProgress`/`FileTransferProgress`). → `FileReceiver`.
- [x] sha256 integrity check (header carries the digest; receiver streams a
      chunked digest and compares on `file-done`, dropping the partial on
      mismatch). Destination defaults to `~/Downloads/Notilus`
      (`getDownloadsDirectory()` + fallback).
- [x] Cancel mid-transfer (either side) + partial-file cleanup:
      `FileSender.cancel()` / `FileReceiver.cancel()` and a `cancel` control
      frame; `TransferController.cancelTransfer(sessionId)` + a cancel button in
      the Transfers activity list.
- [x] **Transport-agnostic design:** the protocol talks to a `TransferConduit`,
      not `RTCDataChannel` directly. `rtc_conduit.dart` (`RtcConduit`) is the only
      native-webrtc piece; `file_transfer.dart` stays testable under `flutter test`.
- [x] Wiring: `TransferController._runTransfer` fires from `_startSession`'s
      `onConnected` — offerer streams `_outgoing[requestId]`, answerer receives
      with the request's file manifest for a correct overall total. `sendFiles`
      replaced the old `sendTransferRequest`; the contact tester now sends a real
      ~4 MB file so a 2-machine run exercises the whole pipeline.
- [x] Unit tests (`test/transfer_protocol_test.dart`, 6) via an in-memory conduit
      pair: multi-file round-trip, name-collision uniquing, sha256-mismatch
      rejection + partial cleanup, cancel frame, backpressure completion, and
      path-traversal filename sanitization — **PASSED**.

**⚠ Verification gap (same as Phase 5):** the live DataChannel + real byte
transfer is unverified until run on **two machines**. To test: add each other as
contacts → contact ⋯ → "Send files (test)" → Accept → watch the "Transfers"
section; received file lands in `~/Downloads/Notilus`.

## Phase 7 — Security & robustness  ✅ DONE (2026-07-06)
- [x] Reject requests from unknown / unverifiable senders — already enforced by
      `_verifiedSender` (must be a saved contact, signature verifies, `to == me`).
- [x] Sign signaling messages with the sender key; verify against saved contact —
      in place since Phase 4 (`signed_messages.dart`; every offer/answer/ICE and
      request/response is signed and verified).
- [x] **Replay / freshness guard:** `verifySignedMessage` now rejects a validly-
      signed message whose `ts` drifts more than `kMessageFreshness` (±5 min) from
      our clock. requestIds are deduped in `TransferController` (bounded FIFO) so a
      replayed request can't re-pop the dialog.
- [x] **DoS bounds:** any authenticated Firebase user can `POST` into an inbox, so
      `_handleRequest` drops (and tidies) requests over `maxFilesPerRequest`
      (1000) / `maxBytesPerRequest` (50 GB) / with negative sizes, and caps the
      pending queue at `maxQueuedRequests` (20).
- [x] **Stage timeouts:** request 60 s, WebRTC connect 30 s (existing) + new
      mid-transfer stall watchdogs — `FileSender` fails if the send buffer won't
      drain and `FileReceiver` fails (+cleans the `.part`) if no frame arrives
      within `stallTimeout` (30 s). A vanished peer no longer hangs the UI.
- [x] **Inbox / RTDB cleanup:** messages deleted once consumed; on decline/timeout
      the sender now sweeps its own request out of the peer's inbox
      (`SignalingService.deletePeerMessage`) so it doesn't orphan when the peer was
      offline. _(Residual: offer/ICE we push aren't individually swept if the peer
      never consumes — noted for a later TTL/janitor pass.)_
- [x] Tests: freshness stale/future rejection (`transfer_signing_test.dart`) and
      sender/receiver stall timeouts (`transfer_protocol_test.dart`) — **PASSED**
      (13 transfer tests green).

## Phase 8 — Background reception (tray)  ✅ DONE (macOS build verified 2026-07-06)
- [x] Run-in-tray via `tray_manager` + `window_manager`; "close = minimize to
      tray" → `TrayService` (`lib/services/tray_service.dart`). `main.dart` does
      `windowManager.ensureInitialized()` + `setPreventClose(true)`;
      `onWindowClose` hides to tray when background reception is on, else quits.
      Tray context menu: Show Notilus / Quit Notilus; icon click shows the window.
- [x] Keep SSE listener alive in background — the inbox stream lives in
      `TransferController`/`SignalingService`, which keep running while the window
      is hidden (only the window is hidden, the app/isolate stays up).
- [x] Raise window on incoming request — `TransferRequestGate._present` calls
      `TrayService.showWindow()` (+focus, un-skip-taskbar) before the Accept
      dialog, so a hidden app pops forward.
- [x] Setting: enable/disable background reception — `SettingsStore`/
      `SettingsProvider.backgroundReception` (default on) + a "Receive in the
      background" switch in the Settings dialog's new "File Transfer" section;
      the toggle updates `TrayService.backgroundEnabled` live.
- [x] Tray icons: reuses `assets/icon/icon.png` (macOS/Linux) and a copied
      `assets/icon/tray_icon.ico` (Windows); both declared as Flutter assets.
- Added packages: `window_manager ^0.5.2`, `tray_manager ^0.5.3`.

**⚠ Verify by hand:** the debug **macOS build links & runs**, but the actual
tray behavior (close→tray, icon menu, raise-on-request) needs eyeballing on a
real desktop session, and Windows/Linux builds haven't been compiled this pass.

## Phase 9 — UI integration into Notilus  ✅ DONE (2026-07-06)
- [x] Sidebar entry / center view for "Transfers" (contacts + activity) — the
      "File Transfer" sidebar entry + `TransferScreen` (Phase 3), with the
      Transfers activity list added in Phase 6.
- [x] Right-click a file/selection → "Send to…" → contact picker. New
      `showSendToSheet` (`lib/screens/transfer/send_to.dart`) + a "Send to…"
      item in the file-list context menu (`file_list_view.dart`, file targets
      only). `_sendPaths` sends the whole multi-selection when the right-clicked
      file is part of it, else just that file; folders are filtered out. The
      contact picker shows online/offline dots. Replaced the temp "Send files
      (test)" tester (removed from the contact sheet).
- [x] Live progress UI (per file + total) + recent-transfer history — the
      Transfers section renders each `BatchProgress` (overall bar + per-file %),
      finished ones persist as history with a "Clear finished" action
      (`clearFinishedTransfers`).
- [x] Empty / error / offline states — `TransferScreen` handles
      not-configured / error / connecting / empty-contacts; the send sheet
      guards not-configured / not-ready / no-contacts / nothing-to-send.
- [x] **Configurable destination** (was deferred from Phase 6): "Save received
      files to" path field in Settings → File Transfer
      (`SettingsStore.transferDestination`); `TransferController._destDir` honors
      it, falling back to `~/Downloads/Notilus`.
- Tests unchanged (UI wiring); `flutter analyze` clean, 33 tests pass.

## Phase 10 — Cross-platform verification  🟣 CODE AIDS DONE · hands-on pending
**Runbook: `docs/P2P_TESTING.md`** — step-by-step for all of the below.
- [x] **Code-side aids for a legible live test:**
      - WebRtcSession logs greppable `[webrtc <id>/<role>]` lines — ICE state
        transitions + gathered candidate types (host / srflx / relay) so you can
        tell LAN-direct vs STUN-traversed vs the no-TURN dead end.
      - The Transfers UI now shows a **Connecting…** entry the moment a session
        starts and flips it to **Failed** with the WebRtcFailure message on a
        dead path — no more silent hang when there's no direct route.
- [ ] Two-machine end-to-end test (same LAN and across the internet). _(hands-on)_
- [ ] Verify on macOS _(debug build links)_, Windows, Linux builds. _(hands-on)_
- [ ] Test networks: home Wi-Fi, phone hotspot; confirm graceful failure on
      symmetric-NAT-both-ends (expected without TURN). _(hands-on)_
- [ ] Large-file + many-file transfer; cancel behavior. _(hands-on — note:
      **resume is not implemented**; a cancelled/interrupted transfer re-sends
      from scratch.)_

---

## Confirmed decisions (2026-07-05)
- **Config delivery:** git-ignored Dart file now (`transfer_config.dart`);
  GitHub secrets later.
- **Received-files destination:** default folder (`~/Downloads/Notilus`),
  changeable in Settings.
- **Incoming alert:** in-app dialog for v1; OS notification added with the tray
  work in Phase 8.
- **Background reception:** yes — build the tray/run-in-background (Phase 8).

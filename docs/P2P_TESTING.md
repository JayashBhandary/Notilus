# Notilus P2P Transfer — Live Testing Runbook (Phase 10)

Everything through Phase 9 is code-complete and unit-tested, but the WebRTC data
path is **native** — it can't run under `flutter test`/`dart run`. This runbook
is the hands-on verification that the DataChannel actually opens and bytes flow,
across the real network scenarios we care about.

You need **two machines** (or two OS installs), each with its own Firebase-backed
identity. They must be added as contacts to each other first.

---

## 0. One-time setup (per machine)

1. Ensure `lib/config/transfer_config.dart` exists with your real RTDB URL + Web
   API key (see `transfer_config.example.dart`). Both machines use the **same**
   Firebase project.
2. Build & run:
   - macOS: `flutter run -d macos` (or `flutter build macos` → open the .app)
   - Windows: `flutter run -d windows`
   - Linux: `flutter run -d linux`
3. Open **File Transfer** in the sidebar. Note each machine's share code (the QR
   / copyable string on the "This device" card).
4. On each machine, **Add** the other's code as a contact. Within ~25 s each
   should flip to a green "Online" dot (heartbeat presence).

If a machine never goes Online for the other, signaling (not WebRTC) is the
problem — check the RTDB rules and that both are on the same Firebase project.

---

## 1. Same-LAN transfer (the easy path)

Both machines on the **same Wi-Fi / LAN**.

1. On machine A, browse to a file, right-click → **Send to…** → pick machine B.
2. Machine B pops an **Accept / Decline** dialog (it raises from the tray if
   hidden). Accept.
3. Watch **File Transfer → Transfers** on both sides:
   - A shows "Sending … · N bytes", B shows "Receiving …", bars advance.
   - On completion both read **Done**; the file is in B's destination folder
     (default `~/Downloads/Notilus`, or the path set in Settings → File
     Transfer).
4. Verify the received file is byte-identical (e.g. `shasum` / `certutil
   -hashfile`). The receiver already checks sha256 and only commits on a match,
   so a "Done" with a saved file means integrity passed.

**Expected candidate type in logs:** `local candidate: host` (see §6). On a LAN
you usually connect on host candidates alone.

---

## 2. Across-the-internet transfer (the real test)

Machines on **different networks** (e.g. A on home Wi-Fi, B on a phone hotspot,
or two different sites).

Same steps as §1. This exercises STUN-assisted NAT traversal. In the logs you
should now see `local candidate: srflx` (server-reflexive, via Google STUN)
being gathered, and the connection should still reach **Done** as long as at
least one side isn't behind symmetric NAT.

---

## 3. The no-TURN dead end (graceful failure)

We ship **no TURN relay** (locked decision, option A), so when *both* ends are
behind symmetric NAT there is no direct path and the transfer **must fail
cleanly**, not hang.

To force it: put **both** machines behind symmetric-NAT-ish networks (two
different carrier-grade-NAT mobile hotspots is the usual way to reproduce).

**Expected:** after the 30 s connect timeout (or an ICE-failed event sooner), the
Transfers entry flips to **Failed** with "Couldn't establish a direct connection
on this network." No partial file is left in the destination. This is the
intended behavior — verify it's a clear message, not a silent hang.

---

## 4. Large-file & many-file

- **Large file:** send a multi-GB file. Watch that memory stays flat (chunked +
  `bufferedAmount` backpressure — the sender should pause when the buffer fills)
  and the bar advances smoothly.
- **Many files:** multi-select a folder's worth of files → Send to…. Each file
  reports its own %, and the overall bar reflects total bytes. Files commit one
  by one.

---

## 5. Cancel (either side)

- Start a large transfer, then hit the **✕** on the Transfers entry (works on the
  sender or the receiver).
- **Expected:** the entry goes **Cancelled** on both sides; the receiver's
  in-progress `.part` file is deleted (no half-file left behind). Already-
  completed files in a multi-file batch stay.

> **Resume is not implemented.** A cancelled or interrupted transfer must be
> re-sent from scratch; there's no partial-resume protocol. (Possible future
> enhancement — out of scope for now.)

---

## 6. Reading the diagnostics

`WebRtcSession` logs greppable lines while connecting (visible in the
`flutter run` console / device logs). Filter with `[webrtc`:

```
[webrtc 1a2b3c4d/offerer] local candidate: host
[webrtc 1a2b3c4d/offerer] local candidate: srflx
[webrtc 1a2b3c4d/offerer] ice state: RTCIceConnectionStateChecking
[webrtc 1a2b3c4d/offerer] ice state: RTCIceConnectionStateConnected
[webrtc 1a2b3c4d/offerer] data channel open — connected
```

- `host` only, then connected → **direct on the LAN**.
- `srflx` gathered, then connected → **NAT-traversed via STUN** (the internet
  case).
- `relay` → would mean TURN, which we don't ship; it should never appear.
- `ice state: …Failed` / `connection state: …Failed`, or the 30 s timeout, then
  a **Failed** Transfers entry → the no-direct-path dead end (§3).

---

## 7. Per-OS build checklist

- [ ] **macOS** — build links & runs _(debug build verified 2026-07-06)_; run
      §1–§5.
- [ ] **Windows** — `flutter build windows`; confirm tray icon (.ico) shows,
      close-to-tray works, run §1–§5.
- [ ] **Linux** — `flutter build linux`; confirm tray + transfers; run §1–§5.
- [ ] Cross-OS pair (e.g. macOS ↔ Windows) end-to-end at least once.

Notes / results (fill in as you go):

| Scenario | A → B | Result | Notes |
|---|---|---|---|
| LAN | | | |
| Internet | | | |
| Symmetric-NAT both | | | (expect graceful fail) |
| Large file | | | |
| Many files | | | |
| Cancel (sender) | | | |
| Cancel (receiver) | | | |

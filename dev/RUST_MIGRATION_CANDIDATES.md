# Notilus — CPU-Heavy Dart Operations / Rust (flutter_rust_bridge) Migration Audit

**Date:** 2026-08-02
**Scope:** `lib/` (83 Dart files, ~21.3k LOC) — analysed against the pattern list:
recursive FS walks, hashing, image/thumbnail work, compression, large collection
loops, duplicate detection, content search, sync I/O, existing isolates, and
large JSON parsing. Anything non-trivial running synchronously on the main
isolate is also flagged as UI-jank risk.

**Key structural finding:** the project has exactly **one** `Isolate.spawn`
(`duplicate_finder_service.dart:170`) and **zero** uses of `compute()`. Every
other heavy path — archive decoding, image base64, JSON of the scan cache,
SHA-256 during P2P receive, folder sort/regroup — runs on the main isolate.
Async ≠ off-thread: `await` only yields around the *I/O wait*; the CPU work
between awaits still executes on the UI thread.

---

## Status

| | |
|---|---|
| **Dart fixes applied** | 6 of 6 — see [Fixed in Dart](#fixed-in-dart-done). `flutter analyze lib/` clean. |
| **Rust core** | Scaffolded at [`core/`](../core/README.md) as `notilus_core`. 47 tests, clippy clean. **Not yet wired into the app** — no `flutter_rust_bridge` dependency yet. |
| **Measured** | `notilus-scan` over this repo: 853 groups / 3200 files / 441 MB reclaimable in **2.07 s**. |

The one pre-existing test failure (`test/widget_test.dart`, "App boots without
crashing") predates this work — confirmed by stashing the changes and re-running.
The 12 pre-existing analyzer errors in `tool/transfer_consent_smoke.dart` are
likewise untouched.

---

## Findings table (sorted High → Low)

| # | Location | What it does | Why it's CPU-heavy | UI thread? | Priority |
|---|----------|--------------|--------------------|------------|----------|
| 1 | `lib/screens/file_preview_screen.dart` `_ArchiveViewState._scan()` | Lists entries in `.zip/.tar/.tar.gz/.tar.bz2/.gz/.bz2/.jar` archives | `readAsBytes()` loads the **entire archive into RAM**, then pure-Dart `ZipDecoder`/`GZipDecoder`/`BZip2Decoder`/`TarDecoder` inflate it. `BZip2Decoder` in Dart is order-of-magnitude slower than libbzip2. A 500 MB zip = multi-second freeze + 500 MB+ heap spike. | ~~YES — main isolate~~ → **fixed (interim)**: now `compute(_decodeArchive, path)` on a background isolate. Still reads the whole file; superseded by `list_archive`. | **High** |
| 2 | `lib/services/duplicate_finder_service.dart:368` `_hashFile()` | Streams SHA-256 over every size-collision candidate | `package:crypto` SHA-256 is pure Dart, no SIMD/SHA-NI. Loop at 270–281 hashes candidates **strictly sequentially** — one file at a time, no I/O parallelism, no partial/head-tail prehash to eliminate non-matches early. This dominates scan wall-clock on any real drive. | No — runs in the spawned isolate (`:170`). UI safe, but single-threaded and slow. | **High** |
| 3 | `lib/services/duplicate_finder_service.dart:302` `_walk()` | Manual recursive directory traversal for the duplicate scan | Async recursion; `dir.list().toList()` (319) **materialises every child of every directory** before iterating; then `FileEntry.from()` (351 → `file_entry.dart:47`) issues a **separate async `stat()` per file**, each a round-trip through Dart's IO thread pool. Millions of files ⇒ millions of futures. Rust `walkdir` + `std::fs::metadata` (or `getdents64`/`FindFirstFileEx`, which return size+mtime inline, zero extra `stat`) is 5–20× faster. | No — in the scan isolate. | **High** |
| 4 | `lib/services/transfer/file_transfer.dart:462`, `:430` (`_startFile` / `_handleBinary`) | Receiver-side chunked SHA-256 over the incoming byte stream | `_digestIn?.add(bytes)` hashes **every received chunk on the main isolate**, at network line rate, for the whole transfer duration. Paired with `socket_conduit.dart:136`, which does `Uint8List.fromList(bytes.sublist(...))` — a **full payload copy per frame**, also on the UI thread. | **YES — main isolate** for the entire transfer. | **High** |
| 5 | `lib/services/transfer/file_transfer.dart:281` `_sha256OfFile()` | Sender-side SHA-256 of each outgoing file before its header | Whole-file pure-Dart hash, per file, awaited inline in `_sendOne` (216) before a single byte ships — the transfer stalls for the full hash duration. | **YES — main isolate.** | **High** |
| 6 | `lib/screens/file_preview_screen.dart` `_SvgViewState._loadBytes()` | Reads (and gunzips `.svgz`) SVG bytes for the preview | `readAsBytes()` + `GZipDecoder().decodeBytes()` on the UI thread — **and it was invoked from inside `build()`**, not cached in a field like `_TextView`/`_MarkdownView` do. Every rebuild re-read and re-gunzipped the file from disk. Bug-grade. | ~~YES, every rebuild~~ → **fixed**: hoisted into a `_future` field in `initState`. | **High** |
| 7 | `lib/services/duplicate_scan_store.dart:44` `load()` | Restores the cached duplicate scan from JSON | `jsonDecode` of a scan cache that can be **many MB** (every duplicate group × every `FileEntry`), then a **serial `await File(f.path).exists()` per file** (line 61) — thousands of sequential syscalls with no batching or concurrency. Then a full sort (70). | **YES — main isolate.** Fired from `duplicate_finder_screen.dart:105` in `initState`, i.e. during the page-open animation. | **Medium-High** |
| 8 | `lib/providers/browser_provider.dart` `_sortedEntries()` | Sorts the current folder's entries | Exposed via the **`entries` getter** — so a full `List.from` + `sort` ran on *every read*. `groupedEntries()` called it again and re-bucketed into a `Map`; `_flatVisibleOrder()` called `groupedEntries()` again. `path_status_bar.dart` triggered a full sort just to read `.length`. On a 10k-entry folder, one `notifyListeners()` = several full sorts + map rebuilds. | ~~YES, every rebuild~~ → **fixed**: `_sortedCache`/`_groupedCache` memoised, invalidated by `_invalidateView()`; new `entryCount` getter for count-only callers. | **Medium-High** |
| 9 | `lib/widgets/marquee_selection.dart:130` `_recompute()` | Rubber-band selection hit-testing | Iterates **every registered item**, calling `findRenderObject()` + `localToGlobal()` + `Rect.overlaps` per item. Invoked on every `onPanUpdate` (116) **and** on a **16 ms `Timer.periodic`** during edge auto-scroll (169 → 183). O(n) render-object geometry at 60 Hz. | **YES — main isolate, by construction** (needs the render tree). | **Medium** |
| 10 | `lib/services/file_service.dart:24` `listDirectory()` | Lists the current folder for the browser | `await for` over `dir.list()` with an async `stat()` per entry (`FileEntry.from`), then a comparator sort (46). Re-run on **every FS watch event** via `browser_provider.dart:170` `_scheduleSilentReload` (180 ms debounce) — a `npm install` in the watched folder re-lists continuously. | **YES — main isolate.** | **Medium** |
| 11 | `lib/providers/browser_provider.dart` `_silentReload()` | Prunes stale selections after a silent re-list | `_selectedPaths.removeWhere((p) => _entries.indexWhere((e) => e.path == p) < 0)` — a **linear scan inside a removeWhere ⇒ O(selected × entries)**. With Cmd+A on a 10k folder that's 10⁸ comparisons, on the UI thread, per watch event. | ~~YES~~ → **fixed**: builds a `Set` of live paths first, O(n); also clears a dangling `_anchorPath`. | **Medium** |
| 12 | `lib/services/duplicate_scan_store.dart:27` `save()` | Persists the scan result | `jsonEncode` of the full group set + `writeAsString`. Called after **every** trash/cleanup action via `_persistCurrent` (`duplicate_finder_screen.dart:283`) — so a bulk cleanup re-serialises the entire (still large) result set each time. | **YES — main isolate.** | **Medium** |
| 13 | `lib/services/file_actions_service.dart:116` `_copyDirectory()` | Recursive folder duplication | Async recursion, one `File.copy` per file, fully sequential, no progress reporting and no cancellation. A large folder duplicate is an unbounded, un-interruptible operation. | **YES — main isolate** (the copies themselves are off-thread I/O, but traversal + orchestration is not, and nothing yields to keep the UI honest). | **Medium** |
| 14 | `lib/services/attachment_service.dart:113–117` `_prepareImage()` | Prepares an image attachment for a vision LLM | `readAsBytes()` up to the 6 MB cap, then `base64Encode(bytes)` — base64 of 6 MB in Dart allocates an ~8 MB string in one synchronous pass. Visible hitch when attaching. | **YES — main isolate.** | **Medium** |
| 15 | `lib/screens/file_preview_screen.dart` `_LinuxPdfViewState._render()`, `_OfficeViewState` | Collects pdftoppm / LibreOffice output pages | **`tmp.listSync()`** — synchronous directory I/O on the UI thread. Worse, `_OfficeView.build()` called **`lengthSync()` + `lastModifiedSync()` on every rebuild** to construct a `FileEntry`. | ~~YES, synchronous~~ → **fixed**: async `.list()`; `_OfficeView` now stats once into a `_convertedEntry` field, so `build()` never touches the disk. | **Medium** |
| 16 | `lib/widgets/file_icon_grid.dart:270`, `:471`; `lib/screens/duplicate_finder_screen.dart:1607`; `lib/widgets/info_panel.dart:189` | Image thumbnails via `Image.file(..., cacheWidth: …)` | Flutter decodes off the UI thread, so this is *not* a jank source today — but there is **no bounded LRU and no on-disk thumbnail cache for images** (only PDFs are cached, `thumbnail_service.dart:57`). Scrolling a large photo folder re-decodes full-resolution JPEG/HEIC repeatedly and inflates the image cache. | No (Flutter's decoder thread), but memory/throughput bound. | **Medium** |
| 17 | `lib/screens/duplicate_finder_screen.dart` `_keepIndex()` | Picks the copy to keep per group | Called from `_groupCardFor`, which the grid builder calls **for every visible card on every rebuild** — recomputing an O(files-in-group) scan instead of caching it. | ~~YES, per rebuild~~ → **fixed**: memoised in `_keepIndexCache`, guarded on `(fileCount, strategy)` so a cleanup that mutates `group.files` in place can't serve a stale index. | **Medium-Low** |
| 18 | `lib/services/workflow_runner.dart:96` `_substitute()` | Fills `{file_content}` / `{step_N}` placeholders | Chained `replaceAll` over a template that has up to 200 KB of file content spliced in, once per placeholder **per step** — O(steps × content) string scanning and reallocation. | **YES — main isolate**, between LLM streaming steps. | **Low-Medium** |
| 19 | `lib/services/thumbnail_service.dart:36` `_hash()` / `:146` binary sniff | FNV-1a over the cache key; 0x00-byte scan over a 2 KB snippet | Tight Dart loops, but over tiny inputs. Included for completeness. | **YES — main isolate**, negligible. | **Low** |
| 20 | `lib/services/transfer/identity_service.dart:78`, `:84` | Ed25519 sign / verify | `package:cryptography` uses a pure-Dart Ed25519 fallback when no platform impl is available — ~ms per op. Per-message, small volume. | **YES — main isolate**, but rare. | **Low** |
| 21 | `lib/services/transfer/signed_messages.dart:7–24` | Canonical (key-sorted) JSON encoding for signing | Recursive walk + per-level `keys.sort()`. Payloads are tiny control messages. | **YES — main isolate**, negligible. | **Low** |
| 22 | `lib/services/settings_store.dart:160`, `:171` | Workflow list JSON round-trip into SharedPreferences | `jsonDecode`/`jsonEncode` of a small user-authored list. | **YES — main isolate**, negligible. | **Low** |
| 23 | `lib/services/system_info_service.dart:78` `_readDf()` / `:145` | Parses `df -k` / PowerShell output with `RegExp(r'\s+')` splits | Tens of lines. Also `shallowBreakdown` (187) is deliberately non-recursive. | **YES — main isolate**, negligible. | **Low** |
| 24 | `lib/utils/device_code.dart:33` | SHA-256 of the public key → short device code | One-shot over ~32 bytes. | **YES**, negligible. | **Low** |

---

## Gap worth noting: no content search exists

The pattern list asks about full-text / regex-over-many-files search. **There is
none in the codebase** — no search field in `home_screen.dart`, no filter in
`BrowserProvider`, no grep-like service. `RegExp` appears only 5 times, all over
tiny strings (`system_info_service.dart:85`, `webrtc_session.dart:70`,
`duplicate_finder_screen.dart:176`, `device_code.dart:41/47`).

If content search is on the roadmap, **do not build it in Dart.** A Rust
implementation over `ignore` (parallel walker) + `grep-searcher`/`memchr` +
`memmap2` gives ripgrep-class throughput for essentially the same integration
cost as the duplicate-scan bridge you'd already have built.

---

## Top 5 to move to Rust first

### 1. Duplicate scanner core — walk + hash (`duplicate_finder_service.dart:302` + `:368`)
The single largest CPU consumer in the app, and the cleanest bridge boundary:
inputs are `(roots, minSize, excludes, extensions, flags)`, output is a stream of
progress events plus a group list. It is *already* isolated behind a
`SendPort`-driven API, so the Dart-side call sites and the whole UI need no
changes — you swap the isolate body for a `flutter_rust_bridge` stream.

Rust wins here compound rather than just being "a faster language":
- **Parallel traversal** — `ignore::WalkBuilder` or `rayon` over `walkdir`; the
  Dart version is strictly single-threaded.
- **No per-file `stat`** — `getdents64` (Linux) / `FindFirstFileEx` (Windows) /
  `readdir` + `d_type` return size and mtime inline. Kills item #3's biggest cost.
- **Hardware SHA** — `sha2` with SHA-NI/NEON is typically **5–15×** faster than
  `package:crypto`, and `rayon` hashes many candidates concurrently.
- **Cheap early-out** — hash the first + last 4 KB before committing to a full
  read. Most size-collisions die instantly; today every candidate is read end to
  end. This alone often halves scan time independent of language.

Do this one first. It's the highest payoff and the lowest integration risk.

### 2. Archive listing / decode (`file_preview_screen.dart:1726`)
The **worst UI-jank offender in the codebase** — a full `readAsBytes` plus
pure-Dart inflate/bunzip2 on the main isolate with no `compute()` anywhere. Rust
`zip` + `flate2` (miniz_oxide or zlib-ng) + `bzip2` + `tar` decode dramatically
faster, and more importantly can **list entries from the central directory
without reading the whole file** — for a zip that's a seek to the end plus a few
KB, not 500 MB into RAM.

Ship this second; it's a small, self-contained function and the user-visible
improvement (freeze → instant) is the most dramatic of anything on the list.

### 3. Transfer hashing + framing (`file_transfer.dart:281`, `:462`; `socket_conduit.dart:136`)
Hashing the receive stream on the UI thread means P2P transfer speed and UI
smoothness are directly coupled — a fast LAN transfer degrades the whole app.
Move chunk hashing (and ideally the length-prefix framing, which currently does a
full `Uint8List.fromList(sublist(...))` copy per frame) behind the bridge. Rust
hashes at multi-GB/s and can hash in place with zero copies. Sender-side, this
also lets you overlap hashing with sending instead of blocking on the full hash
before the first byte ships.

### 4. Scan-cache serialisation + revalidation (`duplicate_scan_store.dart:27`, `:44`)
Two problems in one file: a multi-MB `jsonDecode`/`jsonEncode` on the main
isolate, and a **serial `exists()` per file** during load. In Rust: a compact
binary format (`bincode`/`postcard`) instead of JSON, and a parallel existence
check via `rayon`. This turns a multi-second `initState` stall into imperceptible
work — and since a Rust duplicate scanner (#1) already owns this data structure,
letting it own persistence too is a natural fold-in rather than a separate bridge.

### 5. Directory listing for the browser (`file_service.dart:24` + `file_entry.dart:45`)
Not the biggest single cost, but the **most frequently hit** — every navigation,
plus every debounced FS-watch event. Same `getdents`-vs-`stat` win as #1, and the
sort can come back pre-ordered from Rust so `BrowserProvider` stops re-sorting on
every getter read.

---

## Fixed in Dart (done)

These were algorithmic or lifecycle bugs, not language problems — Rust would
have papered over them. All applied; `flutter analyze lib/` reports no issues.

| Fix | File |
|---|---|
| Memoised `_sortedEntries()` / `groupedEntries()` behind `_invalidateView()`; added an `entryCount` getter so a count-only caller can't force a sort | `providers/browser_provider.dart`, `widgets/path_status_bar.dart` |
| O(selected × entries) selection prune → `Set` lookup, O(n); dangling `_anchorPath` cleared | `providers/browser_provider.dart` |
| `_SvgView._loadBytes()` hoisted out of `build()` into an `initState` field | `screens/file_preview_screen.dart` |
| `_keepIndex()` memoised, revalidated on `(fileCount, strategy)` | `screens/duplicate_finder_screen.dart` |
| `listSync()` → async `list()`; `_OfficeView` stats once into `_convertedEntry` instead of calling `lengthSync()`/`lastModifiedSync()` in `build()` | `screens/file_preview_screen.dart` |
| Archive decode moved to `compute()` — **interim**, superseded by `list_archive` | `screens/file_preview_screen.dart` |

The image thumbnail cache (the sixth item in the original list) is **not** a
Dart fix — it landed in `api::thumbnail` instead. Writing a PNG downscaler in
Dart only to delete it when the bridge lands would have been wasted work.

---

## The Rust core

Scaffolded at [`core/`](../core/README.md) — package `notilus_core` (Cargo
can't have a crate named `core`; that name is the standard library's).

**Built, tested, and not yet wired in.** 47 tests, clippy clean, no
`flutter_rust_bridge` dependency yet — so `cargo test` runs without the Flutter
toolchain. See the crate README for the codegen steps and the one `StreamSink`
shim `scan_duplicates` needs.

| Module | Implements |
|---|---|
| `api::dedupe` | `scan_duplicates` — parallel walk (`ignore`), size bucket, head+tail prefix pass, parallel full hash (`rayon`), hardlink collapsing, polled cancellation |
| `api::hashing` | `hash_file`, `hash_file_prefix` |
| `api::archive` | `list_archive`, `extract_archive_entry` — zip lists from the central directory without inflating |
| `api::listing` | `list_dir` — pre-sorted, size + mtime in one pass |
| `api::thumbnail` | `thumbnail_image`, `cache_key` — FNV-1a matching `thumbnail_service.dart` so the existing on-disk cache stays valid |

Three behaviours the Dart version did not have:

- **A prefix pass**, which is a filter and never a verdict — survivors still get
  a full SHA-256. Guarded by `large_files_differing_only_in_the_middle_survive_the_prefix_pass`.
- **Hardlink collapsing** by `(dev, ino)`. Dart compared path strings, so it
  would offer the user a deletion that frees no space.
- **Deterministic output ordering**, so the scan cache and tests are stable.

### Measured

`notilus-scan` (the CLI in `src/bin/`, added so the pipeline can be timed
against the Dart scanner before the bridge exists):

```
$ cargo run --release --bin notilus-scan -- . --min-size 4096
853 group(s), 3200 file(s), 441 MB reclaimable, in 2.07s
```

### Still to do

1. Run `flutter_rust_bridge_codegen`, add the `StreamSink` shim, add `cargokit`
   platform build hooks.
2. Swap `DuplicateFinderService`'s isolate body for the FRB stream — the Dart
   call sites in `duplicate_finder_screen.dart` need no change.
3. Replace `_decodeArchive` + `compute()` with `list_archive`, and drop the
   `archive` pub dependency.
4. Move transfer hashing (`file_transfer.dart`) onto `hash_file` — still the
   highest-value unfixed item, since it currently hashes the receive stream on
   the UI thread at network line rate.
5. Scan-cache persistence (`duplicate_scan_store.dart`) — binary format plus a
   parallel existence check, folded into the dedupe module.

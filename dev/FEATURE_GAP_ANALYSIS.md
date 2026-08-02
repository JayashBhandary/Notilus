# Notilus — File Manager Feature Gap Analysis

**Originally assessed:** 2026-08-02 · **Updated after the must-have implementation pass:** 2026-08-02
**Method:** every item on the must/should/nice list checked against `lib/` and `core/`. Verified by reading the implementing code, not by searching for keywords — several items look present from a grep and are not (see [Dead UI](#dead-ui-still-worth-knowing-about)).

**Legend:** ✅ done · 🟡 partial · ❌ missing

**Verification at time of update:** Rust 87 tests · clippy 0 lints · Dart 38 tests (suite green) · `flutter analyze lib/` clean · `flutter build macos` ✓.

---

## Where things stand

The original finding was that **the feature profile was inverted** — strong on differentiators (previews, duplicate detection, terminal, plus AI chat and P2P transfer that aren't on the list at all), weak on table stakes. Specifically: you could not copy, cut, paste, or move a file, and there was no drag and drop and no search.

**That inversion is corrected.** The must-have tier is complete, and the CPU-bound half of it runs in a native Rust core (`core/`, package `notilus_core`) reached through `flutter_rust_bridge`. Notilus is now a file manager rather than a file viewer.

The remaining gaps are concentrated in should-have parity features — tabs, dual-pane, undo, bulk rename — and in a handful of Rust capabilities that are **written and bridged but not yet called from the UI**.

### Scorecard

| Tier | ✅ | 🟡 | ❌ | Effective |
|---|---|---|---|---|
| **Must-have** (12) | 5 → **12** | 4 → 0 | 3 → 0 | ~55% → **100%** |
| **Should-have** (14) | 2 → **5** | 3 → 3 | 9 → 6 | ~25% → **~46%** |
| **Nice-to-have** (12) | 2 → 2 | 3 → 3 | 7 → 7 | **~25%** |

Implementation detail for the must-have work is in [`MUST_HAVE_IMPLEMENTATION.md`](MUST_HAVE_IMPLEMENTATION.md); the performance audit that produced the Rust core is in [`RUST_MIGRATION_CANDIDATES.md`](RUST_MIGRATION_CANDIDATES.md).

---

## Must-have — core file browser

| # | Feature | Status | Notes |
|---|---|---|---|
| 1 | **Navigation** | ✅ | Sidebar, breadcrumbs, back/forward, **Up button**, and a **typable address bar** (`widgets/address_bar.dart`) reached by clicking the path or Cmd/Ctrl+L. Accepts `~`, relative paths, and a path to a *file* (lands on its folder with it selected). ⚠️ The **sidebar is still a flat list**, not an expandable folder tree — see [Still open](#still-open). |
| 2 | **File operations** | ✅ | Copy, cut, paste, move, rename, duplicate, New Folder, New File, trash. Clipboard lives in `FileOpsProvider`; every mutation runs in `core::api::fileops`. |
| 3 | **Multi-select** | ✅ | Click, Cmd/Ctrl-click, Shift-click range, Cmd+A, marquee drag with edge auto-scroll. Unchanged — it was already complete. |
| 4 | **Views** | ✅ | Icons + list, sortable **Name / Kind / Date modified / Size** columns, adjustable row density, optional grouping by kind. Columns are still not user-resizable, which is a refinement rather than a gap. |
| 5 | **Sorting** | ✅ | All four fields, asc/desc, directories pinned first. Memoised, so re-sorting never touches the disk. |
| 6 | **Drag and drop** | ✅ | In-app **and** to/from the OS, via `super_drag_and_drop` (`widgets/file_drag_drop.dart`). Rows and grid tiles are sources; folder rows and the listing background are targets. Plain drag moves, Option/Ctrl copies — evaluated at drop time. |
| 7 | **Context menus** | ✅ | Now includes Copy / Cut / Paste (with a live item count), New File, and Show Hidden Files alongside the original entries. |
| 8 | **Basic search** | ✅ | Overshot the requirement: filename **and** content search, recursive over the whole subtree, streaming results as they're found (`core::api::search`, parallel walk + SIMD substring). This also closes should-have #3. |
| 9 | **Copy progress** | ✅ | Determinate bar with live file/byte counts and a working Cancel, from a recursive pre-pass that totals the work first. Cancellation is polled between files *and* between 1 MB chunks. |
| 10 | **Keyboard shortcuts** | ✅ | Ctrl/Cmd+C·X·V·A·L·H, Ctrl/Cmd+↑, Del, Shift+Del, F2, Enter, ↑/↓, Shift+↑/↓, Space. |
| 11 | **Trash** | ✅ | Real recycle bin on **all three** desktops via the `trash` crate — `IFileOperation` on Windows, XDG trash on Linux, `NSFileManager` on macOS. This closed a genuine data-loss bug: the Dart path hard-deleted on Windows and Linux with no undo anywhere in the app. |
| 12 | **Preview / thumbnails** | ✅ | Unchanged and already strong: images, SVG/SVGZ, PDF, text, Markdown, Office, archives, video, audio. |

---

## Should-have — competitive parity

| # | Feature | Status | Notes |
|---|---|---|---|
| 1 | **Tabs** | ❌ | No tab model. Blocked on the `BrowserProvider` split — see [One structural note](#one-structural-note). |
| 2 | **Dual-pane** | ❌ | Same blocker. Cheapest big win once the provider is per-pane, since copy/move now exists. |
| 3 | **Fast recursive search** | ✅ | Delivered with must-have #8. Parallel `ignore` walk, `memchr::memmem` content matching, streaming, cancellable, binary sniffing, `max_results` cap. |
| 4 | **Rich previews** | 🟡 | Unchanged. Still missing the *metadata* half — no EXIF, no media duration/codec/bitrate. |
| 5 | **Bulk rename** | ❌ | Nothing. `rename_path` exists in the core; the pattern/preview UI does not. |
| 6 | **Thumbnail cache** | 🟡 | **Written but not wired.** `core::api::thumbnail` implements downscaling plus a `cache_key` that deliberately matches the Dart FNV-1a scheme, so the existing on-disk PDF cache stays valid. Nothing in `lib/` calls it yet — image tiles still use `Image.file(cacheWidth:)`, which re-decodes on scroll-back. |
| 7 | **Properties panel** | 🟡 | Unchanged: name, kind, size, modified, path. No permissions, owner, EXIF or media info. |
| 8 | **Favorites / bookmarks** | 🟡 | Unchanged. Still the 4 hardcoded OS shortcuts; users cannot add, remove or reorder. |
| 9 | **Recent files / locations** | ❌ | Nothing persisted. Back/forward is in-memory and dies with the session. |
| 10 | **Hidden files toggle** | ✅ | Cmd/Ctrl+H or the background context menu. The filter is applied natively during the directory read rather than on the result. |
| 11 | **Sort/view memory per folder** | ❌ | Not per-folder, and still not globally persisted — view state resets on launch. |
| 12 | **Undo/redo** | ❌ | Still nothing. Less dangerous than it was (deletes now go to a real recycle bin on every platform), but a paste-over or a move to the wrong folder is still unrecoverable in-app. |
| 13 | **Compression** | 🟡 | **Partly written, not wired.** `list_archive` reads a zip's central directory without inflating, and `extract_archive_entry` works — both bridged. The preview still uses the Dart `compute(_decodeArchive)` path added as an interim fix, and there is no extract-to-disk and no zip creation. |
| 14 | **Duplicate finder** | ✅ | Now runs the Rust scanner: parallel walk, parallel hashing, a head+tail prefix pass that avoids reading most candidates in full, and hardlink collapsing (the Dart version reported hardlinks as reclaimable when deleting them frees nothing). The Dart service kept its API, so the screen is unchanged. |

---

## Nice-to-have — differentiators

| # | Feature | Status | Notes |
|---|---|---|---|
| 1 | **Cloud connectors** | ❌ | — |
| 2 | **Smart/saved searches** | ❌ | Now unblocked — search exists, so a saved query is a persistence + sidebar problem rather than an engine problem. |
| 3 | **Tagging / labels** | 🟡 | ⚠️ Still **dead UI** — `sidebar.dart` renders 7 colour tags with `onTap: () {}`. |
| 4 | **File conversion** | ❌ | No user-facing conversion. LibreOffice/poppler plumbing exists but only feeds the LLM and the preview. |
| 5 | **Batch operations pipeline** | 🟡 | "Workflows" are **LLM prompt chains**, not file-operation pipelines. Different feature wearing a similar name. |
| 6 | **Themes / dark mode** | ✅ | Full system/light/dark. |
| 7 | **Split view + sync scroll** | ❌ | Same provider blocker as tabs/dual-pane. |
| 8 | **Checksums UI** | ❌ | `hash_file` is written **and bridged** through `NativeCore.hashFile`. Nothing calls it — this is a panel away from done. |
| 9 | **Terminal integration** | ✅ | Embedded xterm + `flutter_pty`, follows cwd, Cmd/Ctrl+J. |
| 10 | **Network locations** | ❌ | No SMB/FTP/SFTP. |
| 11 | **Storage analyzer** | 🟡 | Unchanged: usage bars plus a **one-level, non-recursive** category breakdown that counts files rather than sizing them. No treemap. The parallel walker needed for a real recursive sizing pass already exists in `api::dedupe`. |
| 12 | **Plugin system** | ❌ | — |

---

## Still open

Ordered by what a user notices first.

| Item | Tier | Note |
|---|---|---|
| **Sidebar folder tree** | must #1 | The one navigation piece not built. Grouped with the address bar in the original entry; it is separate work and is not claimed. |
| **Tabs / dual-pane / split view** | should #1–2, nice #7 | All three are the same refactor. See below. |
| **Undo/redo** | should #12 | The highest-value safety feature left. |
| **Wire the four written-but-unused Rust capabilities** | should #6, #13; nice #8, #11 | Thumbnail cache, archive extract, checksums panel, recursive storage sizing. Each is bridged or a small addition away from bridged. |
| **Bulk rename, recents, persisted view state, user-managed favorites, EXIF/media metadata** | should | Conventional parity work, no blockers. |

---

## What you have that isn't on the list

Still worth keeping in view when prioritising — real, substantial, and unusual for a file manager:

- **Multi-provider AI chat** — Ollama, Claude, Gemini, OpenAI behind one `LlmClient`, with file attachments.
- **P2P file transfer** — WebRTC + LAN discovery, Ed25519-signed messages, QR contact exchange, chunked SHA-256-verified transfers, consent gating.
- **LLM workflows** — user-authored prompt chains over a selected file.
- **AI system insight** — LLM commentary on disk usage.
- **A tested native core** — `core/` is 87 tests and clippy-clean, reusable outside Flutter (there is a `notilus-scan` CLI in `src/bin/` for benchmarking).

---

## Dead UI (still worth knowing about)

Both of these still advertise capability that doesn't exist. Cheap to fix, expensive to leave:

1. **Tags** (`sidebar.dart`) — 7 colour rows, `onTap: () {}`.
2. **"Favorites"** (`sidebar.dart`) — reads as user-managed bookmarks; is actually 4 fixed OS folders.

---

## Suggested build order

Group 1 from the original plan is **done**. What follows replaces it.

### 1. The provider split — do this first

`BrowserProvider` is still an **app-wide singleton**: one `_currentPath`, one `_entries`, one selection, one back/forward stack. Tabs, dual-pane and split view are all the same refactor, and it gets more expensive with every feature stacked on top.

Three roadmap items unlock at once. Nothing else on the list has that ratio.

### 2. Cash in what's already built

Four Rust capabilities are written and tested; they need call sites, not implementation.

| Work | State |
|---|---|
| **Image thumbnail cache** | `thumbnail_image` + `cache_key` written and bridged; swap the `Image.file` tiles onto it |
| **Archive extract-to-disk** | `list_archive` + `extract_archive_entry` written and bridged; replace the interim `compute(_decodeArchive)` path and add extract/create UI |
| **Checksums panel** | `hash_file` bridged; needs UI only |
| **Storage analyzer / treemap** | Replace one-level `shallowBreakdown` with a recursive parallel sizing pass, then a treemap widget |

### 3. Safety and parity

Undo/redo first — it is the last item where a misclick costs real work. Then bulk rename, recents, persisted per-folder view state, user-managed favorites, and EXIF/media metadata in the properties panel.

### 4. Differentiators

Wire or remove tags — dead UI is worse than no UI. Then saved searches (now unblocked), file conversion, and a file-operation batch pipeline distinct from the LLM workflows.

---

## One structural note

`BrowserProvider` remains a singleton for the whole app. This was flagged in the original analysis and is still true — the must-have work deliberately did not touch it, to keep that change reviewable.

If tabs, dual-pane or split view are on the roadmap at all, do the split **before** group 2, not after.

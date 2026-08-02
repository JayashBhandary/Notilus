# Must-Have Implementation — CPU-Heavy Work in Rust

**Date:** 2026-08-02
**Scope:** the must-have tier of [`FEATURE_GAP_ANALYSIS.md`](FEATURE_GAP_ANALYSIS.md), with every CPU-bound part implemented in the Rust core rather than Dart.

**Verified:** `cargo test` 87 passing · `cargo clippy --all-targets` 0 lints · `flutter test` **38 passing (suite fully green)** · `flutter analyze lib/` no issues · `flutter build macos` ✓ links and bundles the Rust staticlib · app launches and runs without crashing.

**Status: complete.** The must-have tier is closed, and the three follow-up items in *Notes for the next pass* are done too.

---

## The bridge is live

Previously the Rust core existed but was not wired in. It is now connected end to end:

| Step | State |
|---|---|
| `flutter_rust_bridge` 2.12.0, Rust + Dart pinned to the same version | ✓ |
| `api::bridge` as the sole codegen surface (`rust_input: crate::api::bridge`) | ✓ |
| Generated `frb_generated.rs` + `lib/src/rust/**` | ✓ |
| cargokit platform build via `rust_builder/`, pointed at the existing `core/` crate | ✓ |
| macOS app builds, links `libnotilus_core.a`, and bundles it | ✓ |

Pointing `rust_input` at one adapter module rather than `crate::api` keeps the rest of the crate free to use generics, borrowed parameters and callbacks — so `cargo test` still runs without the Flutter toolchain, and the `notilus-scan` CLI still reuses the same functions.

**Cancellation.** A `StreamSink` only flows Rust → Dart, so it can't carry a stop request. Long operations take a caller-chosen `opId`, register a `CancelToken` under it for their duration, and Dart calls `cancelOp(opId)` to stop them. Registry entries are removed on both the success and error paths.

Two incidental fixes were required: the Dart SDK floor moved `>=3.0.0` → `>=3.3.0` (FRB's generated web interop uses extension types; CI already pins Flutter 3.44 / Dart 3.12), and `freezed` was added for the generated union types.

---

## What shipped

| # | Must-have | Before | Now |
|---|---|---|---|
| 2 | **File operations** | 🟡 no copy/cut/paste/move at all | ✅ full clipboard, paste, move, New File — all through Rust |
| 8 | **Search** | ❌ nothing | ✅ filename **and** content, recursive over the subtree, streaming |
| 9 | **Copy progress** | ❌ nothing, uninterruptible | ✅ determinate bar with live byte/file counts and working Cancel |
| 10 | **Keyboard shortcuts** | 🟡 two keys | ✅ Ctrl/Cmd+C·X·V·A, Del, Shift+Del, F2, Enter, ↑/↓, Shift+↑/↓ |
| 11 | **Trash** | 🟡 hard-delete on Windows/Linux | ✅ real recycle bin on all three desktops |

Search overshot the must-have tier: the requirement was filename search in the current folder, and what landed is recursive subtree search with optional content grep — which also closes should-have #3.

### Rust modules added

| Module | Provides | Tests |
|---|---|---|
| `api::fileops` | `copy_paths`, `move_paths`, `measure`, `create_file`, `create_dir`, `rename_path` | 18 |
| `api::search` | `search_files` — parallel walk, wildcard names, SIMD content matching | 14 |
| `api::trash` | `move_to_trash`, `delete_permanently` | 4 |
| `api::bridge` | the FFI adapter + cancellation registry | 3 |

### Behaviour the Dart version never had

- **Progress from a real total.** A recursive pre-pass counts files and bytes first, so the bar is determinate rather than a spinner.
- **Cancellation that actually stops work.** Polled between files *and* between 1 MB chunks, so a stuck 40 GB copy aborts promptly.
- **Partial-write cleanup.** A cancelled or failed copy removes its half-written destination instead of leaving something that looks complete.
- **Cross-device move.** `rename(2)` first — instant on the same filesystem — falling back to copy-then-delete on `EXDEV`. Moving to a USB stick fails outright without this.
- **Containment refusal.** Copying a folder into its own subtree is rejected before anything is written, rather than recursing until the disk fills.
- **Permissions and symlinks preserved.** The executable bit survives a copy (a copied script that won't run is a bug); symlinks are copied as links, not followed.

---

## Two bugs the tests caught

**Self-move would have duplicated instead of no-op'ing.** Dragging a file into the folder it already lives in resolved the collision *first*: under `Collision::Rename` the target became `a copy.txt`, so the same-file guard never fired and the "move" silently became a duplicate. The containment check now runs before collision resolution. Covered by `moving_onto_itself_is_a_no_op_not_a_deletion` — the dangerous shape of this bug is that a rename-to-self followed by source cleanup deletes the user's data.

**The prefix pass could have promoted a false duplicate.** Guarded by `large_files_differing_only_in_the_middle_survive_the_prefix_pass`: two files sharing size, head and tail but differing mid-file must still be separated by the full hash. The head+tail fingerprint is a filter, never a verdict.

---

## Second pass — the remaining must-haves

| # | Item | Status |
|---|---|---|
| 6 | **Drag and drop** | ✅ In-app **and** to/from the OS, via `super_drag_and_drop` |
| 1 | **Address bar + Up button** | ✅ Typable path field with `~` and relative-path support; Up button; Cmd/Ctrl+L |
| 4 | **Kind column** | ✅ Sortable Kind column in list view |

**Drag and drop** (`widgets/file_drag_drop.dart`). `super_drag_and_drop` rather
than Flutter's `Draggable`, because only a platform drag session can hand a real
file URI to Finder or Explorer. Rows and grid tiles are drag sources; folder rows
and the listing background are drop targets. A plain drag **moves**, Option
(macOS) / Ctrl (elsewhere) **copies** — read at drop time, not drag start, so the
user can change their mind mid-drag. Both routes go through `FileOpsProvider`, so
a drag gets the same progress bar, cancellation and collision handling as a
paste. Dropping a folder onto itself, or items back into the folder they already
occupy, shows "no" on hover rather than failing after the fact.

**Address bar** (`widgets/address_bar.dart`). Breadcrumbs are the resting state;
clicking the path area or pressing Cmd/Ctrl+L swaps in a text field pre-filled
and selected. Accepts `~`, relative paths, and a path to a *file* — which lands
on its folder with it selected, because pasting a full file path is a normal
thing to do. Losing focus reverts rather than stranding the user in a text box.

The **folder tree** in the sidebar is still not built — it was grouped with the
address bar in the original entry, but it is a separate piece of work and is not
claimed here.

### Also closed from *Notes for the next pass*

- **`BrowserProvider` now lists through Rust.** `FileService.listDirectory` keeps
  its signature and calls `list_dir` internally, so the seam is one file. The
  provider keeps its memoised Dart sort deliberately: re-sorting a column should
  reorder instantly, not go back to disk.
- **The duplicate finder now runs the Rust scanner.** `DuplicateFinderService`
  keeps its Dart types and public API — the screen is unchanged — and its ~200
  lines of walk-and-hash were replaced by a stream from the core. This is what
  resolved the `DuplicateGroup`/`ScanProgress` name clash: the mapping happens in
  one service instead of leaking rust types into the UI.
- **`FileActionsService` collapsed.** Rename, duplicate, trash and `trashAll` are
  gone; rename and duplicate now call the core. What remains is genuine shell
  integration: open, open-with, reveal, copy-path.

### Bonus, since the plumbing was already there

- **Hidden files toggle** (should-have #10) — the filter is applied natively
  during the directory read. Cmd/Ctrl+H, or the background context menu.
- **Cmd/Ctrl+↑** for Up.

## Platform gotcha: drag-and-drop vs. Flutter's merged UI thread

Adding `super_drag_and_drop` made the app **segfault on launch** (`SIGSEGV`,
`KERN_INVALID_ADDRESS at 0x8`). Not a Rust bug — the crashing frame was:

```
0  libobjc.A.dylib          objc_loadWeakRetained + 14
1  irondash_engine_context  +[IrondashEngineContextPlugin getFlutterView:]
…
10 super_native_extensions  PlatformDropContext::new      (drop.rs:271)
11 super_native_extensions  DropManager::new_context      (drop_manager.rs:200)
```

Flutter 3.44 runs the UI and platform threads **merged** by default on macOS —
the `Running with merged UI and platform thread. Experimental.` line at startup.
`irondash_engine_context` (which `super_native_extensions` is built on) isn't
compatible: `getFlutterView:` weak-loads a `FlutterView` that isn't valid under
the merged model, so the load faults the instant the first `DropRegion` is
created — i.e. the moment the folder drop targets first build.

Fixed by opting out in `macos/Runner/Info.plist`:

```xml
<key>FLTEnableMergedPlatformUIThread</key>
<false/>
```

Revisit when `irondash_engine_context` supports merged threads; the key can
then be removed. **Windows and Linux are unaffected** — the merged-thread mode
is Apple-platform only, so no equivalent change is needed there.

## Dart tests now exercise the real Rust core

The duplicate-finder tests would have become vacuous once the engine moved
out of Dart. Instead of deleting them, `test/native_test_support.dart` opens the
`cargo build` output directly, so those tests now drive the same native code the
app ships — genuine cross-boundary coverage rather than a Dart stand-in. They
skip with a clear reason if the library hasn't been built.

The suite is fully green for the first time: the long-standing
`widget_test.dart` failure was `DotEnv has not been initialized`, which `main()`
normally handles before the first frame. Two lines in `setUpAll` fixed it.

---

## Notes for the next pass

- **`FileActionsService` is now half-dead.** `rename`, `duplicate`, `trash` and `trashAll` are superseded by the Rust paths. `openInDefaultApp`, `openWithChooser`, `revealInOs` and `copyPath` are still live. Worth collapsing.
- **The duplicate finder still runs the Dart isolate scanner.** Only its cleanup was moved onto Rust trash. `scan_duplicates_stream` is generated and waiting; swapping it needs the `DuplicateGroup`/`ScanProgress` name clash resolved (the screen currently imports `native_core.dart` with an `as native` prefix for exactly this reason).
- **`BrowserProvider` still lists directories through Dart.** `list_dir` is bridged and pre-sorts, but the provider was left on `FileService` to keep this change reviewable.
- **The sidebar folder tree** is the one navigation item still outstanding.
- **`BrowserProvider` is still an app-wide singleton** — one path, one selection,
  one history. Tabs, dual-pane and split view all need it per-pane, and that
  refactor gets more expensive with each feature stacked on top.

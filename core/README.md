# `notilus_core`

Native core for Notilus — the CPU-bound work that used to run in Dart.

Motivated by the audit in [`dev/RUST_MIGRATION_CANDIDATES.md`](../dev/RUST_MIGRATION_CANDIDATES.md).
Each module below maps to a numbered finding there.

> The crate directory is `core/` but the **package** is `notilus_core`. Cargo
> can't have a crate named `core` — that name belongs to the Rust standard
> library and the compiler would refuse to link it.

## What's here

| Module | Replaces | Why it moved |
|---|---|---|
| `api::dedupe` | `services/duplicate_finder_service.dart` | Parallel walk, parallel hashing, a head+tail prefix pass, and hardlink collapsing — none of which the Dart version had |
| `api::hashing` | `_hashFile`, `file_transfer.dart` hashers | `package:crypto` is pure Dart with no SHA-NI/NEON access |
| `api::archive` | `_ArchiveView._scan` in `file_preview_screen.dart` | Listing a zip reads the central directory only, instead of `readAsBytes()` on the whole file plus a pure-Dart inflate on the UI thread |
| `api::listing` | `file_service.dart:listDirectory` + `FileEntry.from` | One native pass instead of an awaited `stat()` per entry, sorted before Dart sees it |
| `api::thumbnail` | gap — no image thumbnail cache existed | Downscale once to a small PNG rather than re-decoding full-resolution source on every scroll |

## Status

**The crate builds, is tested, and is not yet wired into the app.** It has no
`flutter_rust_bridge` dependency, so `cargo test` runs without the Flutter
toolchain and the same functions are reusable from a CLI or benchmark.

```
cargo test        # 47 tests
cargo clippy --all-targets
```

Everything in `src/api/` is written against bridge-compatible types — `String`,
`u64`, `bool`, `Vec<T>`, `Option<T>`, and plain structs/enums of the same — so
codegen can mirror it into Dart without hand-written glue.

## Try it without Flutter

`notilus-scan` runs the duplicate pipeline from a terminal. Point it and the
current in-app scanner at the same folder to compare wall-clock and results.

```bash
cargo run --release --bin notilus-scan -- ~/Pictures --defaults
cargo run --release --bin notilus-scan -- / --min-size 1048576 --defaults --quiet
```

## Wiring up flutter_rust_bridge

1. Install the codegen and add the runtime dependency:

   ```bash
   cargo install flutter_rust_bridge_codegen
   flutter pub add flutter_rust_bridge
   cargo add flutter_rust_bridge --manifest-path core/Cargo.toml
   ```

2. Generate, from the repository root:

   ```bash
   flutter_rust_bridge_codegen generate --config-file core/flutter_rust_bridge.yaml
   ```

3. Uncomment `mod frb_generated;` in `src/lib.rs`.

4. Add the platform build hooks — `cargokit` (which FRB scaffolds) for
   macOS/Windows/Linux, so `flutter build` compiles the crate as part of the
   normal build rather than as a separate manual step.

### The one signature that needs a shim

`scan_duplicates` takes a generic `F: Fn(ScanProgress)` callback, which codegen
can't mirror. Wrap it in a non-generic function that forwards to a `StreamSink`
— this is the only piece of glue the design needs:

```rust
// src/api/bridge.rs — add once FRB is a dependency.
use flutter_rust_bridge::frb;

#[frb]
pub fn scan_duplicates_stream(
    req: ScanRequest,
    sink: StreamSink<ScanEvent>,
) -> Result<(), String> {
    let cancel = CancelToken::new();           // register in a handle map to
                                               // support cancel() from Dart
    let progress_sink = sink.clone();
    let groups = scan_duplicates(req, &cancel, move |p| {
        let _ = progress_sink.add(ScanEvent::Progress(p));
    })?;
    let _ = sink.add(ScanEvent::Done(groups));
    Ok(())
}
```

`CancelToken` is already `Clone` + `Send` + `Sync` for exactly this: hold one in
a map keyed by scan id so Dart's existing "Stop" button can flip it.

### Dart-side call sites

The Dart API was left shaped so the swap is small:

- `DuplicateFinderService.scan()` already hides its isolate behind a
  `Future` + progress callback. Replacing the isolate body with the FRB stream
  needs no change in `duplicate_finder_screen.dart`.
- `_ArchiveView._scan()` currently calls `compute(_decodeArchive, path)` — an
  interim fix so the UI stops freezing before this crate is wired. It becomes a
  call to `listArchive`, and `_decodeArchive` plus the `archive` pub dependency
  can be deleted.
- `FileService.listDirectory` returns `DirectoryListing`; `list_dir` returns the
  same fields pre-sorted, so `BrowserProvider` can stop sorting entirely.

## Design notes

**The prefix pass is a filter, never a verdict.** `hash_file_prefix` hashes the
first and last 4 KB plus the length. Two files that survive it still get a full
SHA-256 before being reported. `large_files_differing_only_in_the_middle_survive_the_prefix_pass`
in `dedupe.rs` is the regression guard.

**Hardlinks are not duplicates.** Deleting one name for a shared inode reclaims
nothing, so `dedupe_same_inode` collapses them by `(dev, ino)` on Unix. The Dart
version compared path strings and would have offered the user a deletion that
freed no space.

**Cancellation is polled everywhere.** The walk returns `WalkState::Quit`, and
both hash passes check between files, so a cancelled scan stops promptly instead
of running to completion and discarding the result.

**Extraction is capped.** `MAX_EXTRACT_BYTES` (512 MB) bounds a single archive
entry, and the reader takes one byte past the cap so an entry that lies about
its declared size is rejected rather than silently truncated.

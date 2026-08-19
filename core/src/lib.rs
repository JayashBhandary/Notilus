//! Native core for Notilus.
//!
//! This crate holds the CPU-bound work that used to run in Dart: recursive
//! filesystem walking, SHA-256 hashing, duplicate detection, archive reading
//! and image thumbnailing. See `dev/RUST_MIGRATION_CANDIDATES.md` in the
//! repository root for the audit that motivated each module.
//!
//! # Layout
//!
//! Everything Dart calls lives under [`api`]. Those modules are deliberately
//! written against plain types — `String`, `u64`, `Vec<T>`, `Option<T>`, and
//! structs/enums of the same — because that is the subset
//! `flutter_rust_bridge` can mirror into Dart without hand-written glue.
//!
//! # Bridge
//!
//! [`api::bridge`] is the only module `flutter_rust_bridge` looks at — see
//! `flutter_rust_bridge.yaml`. Everything else stays free to use generics,
//! borrowed parameters and callbacks the bridge can't mirror, which is why
//! `cargo test` still runs without the Flutter toolchain and why the CLI in
//! `src/bin/` can reuse the same functions.
//!
//! Regenerate after changing any signature in `api::bridge`:
//!
//! ```text
//! flutter_rust_bridge_codegen generate --config-file core/flutter_rust_bridge.yaml
//! ```

pub mod api;
mod frb_generated;

pub use api::archive::{extract_archive_entry, list_archive, ArchiveEntry};
pub use api::dedupe::{
    scan_duplicates, CancelToken, DuplicateGroup, ScanProgress, ScanRequest,
};
pub use api::fileops::{
    copy_paths, create_dir, create_file, move_paths, rename_path, Collision, FailedItem,
    OpOutcome, OpProgress,
};
pub use api::hashing::{hash_file, hash_file_prefix};
pub use api::quick::{
    compress_paths, convert_image, extract_archive, folder_stats, transform_image,
    FolderStats, ImageTarget, ImageTransform, QuickOutcome, QuickProgress,
};
pub use api::search::{search_files, HitKind, SearchHit, SearchRequest, SearchSummary};
pub use api::trash::{delete_permanently, move_to_trash, TrashOutcome};
pub use api::listing::{list_dir, DirEntryInfo, SortField, SortSpec};
pub use api::thumbnail::{thumbnail_image, ThumbnailInfo};

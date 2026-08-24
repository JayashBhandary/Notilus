//! The flutter_rust_bridge surface — the *only* module codegen looks at.
//!
//! `flutter_rust_bridge.yaml` points `rust_input` here rather than at
//! `crate::api`, so the rest of the crate stays free to use generics,
//! borrowed parameters and callbacks that the bridge can't mirror. This module
//! is the adapter layer: non-generic signatures, owned arguments, and
//! `StreamSink` in place of progress closures.
//!
//! ## Cancellation
//!
//! A `StreamSink` gives Dart a way to *receive*, not to talk back. Long
//! operations therefore take an `op_id` chosen by the caller and register a
//! [`CancelToken`] under it for the duration; Dart calls [`cancel_op`] with the
//! same id to stop the work. Ids are opaque strings — the Dart side uses a
//! UUID.

use crate::api::dedupe::{self, CancelToken, DuplicateGroup, ScanProgress, ScanRequest};
use crate::api::email::{self, EmailAttachmentData, EmailMessageInfo};
use crate::api::sharing::{
    self, SmbClientSettings, SmbEntry, SmbOpenFile, SmbServerEvent, SmbServerSettings,
    SmbServerStatus, SmbSession,
};
use crate::api::fileops::{self, Collision, OpOutcome, OpProgress};
use crate::api::listing::{DirEntryInfo, SortSpec};
use crate::api::quick::{
    self, FolderStats, ImageTarget, ImageTransform, QuickOutcome, QuickProgress,
};
use crate::api::search::{self, SearchHit, SearchRequest, SearchSummary};
use crate::api::thumbnail::ThumbnailInfo;
use crate::api::trash::TrashOutcome;
use crate::api::{archive, hashing, listing, thumbnail, trash};
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// Called once from Dart before anything else, to install panic handlers and
/// logging so a Rust panic surfaces as a Dart exception instead of a crash.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// ── cancellation registry ──────────────────────────────────────────────────

fn registry() -> &'static Mutex<HashMap<String, CancelToken>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, CancelToken>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Registers a fresh token under `op_id`, replacing any stale entry.
fn begin(op_id: &str) -> CancelToken {
    let token = CancelToken::new();
    if let Ok(mut map) = registry().lock() {
        map.insert(op_id.to_string(), token.clone());
    }
    token
}

/// Drops the token. Always called, including on the error path, so a failed
/// operation can't leak an entry that a later run with the same id would find.
fn end(op_id: &str) {
    if let Ok(mut map) = registry().lock() {
        map.remove(op_id);
    }
}

/// Cancels the in-flight operation registered under `op_id`.
///
/// Returns false if nothing was registered — normal when the operation
/// finished between the user's click and this call arriving.
pub fn cancel_op(op_id: String) -> bool {
    match registry().lock() {
        Ok(map) => match map.get(&op_id) {
            Some(token) => {
                token.cancel();
                true
            }
            None => false,
        },
        Err(_) => false,
    }
}

// ── duplicate scan ─────────────────────────────────────────────────────────

/// Progress or completion for a duplicate scan.
#[derive(Clone, Debug)]
pub enum ScanEvent {
    Progress(ScanProgress),
    Done(Vec<DuplicateGroup>),
}

/// Streams a duplicate scan. Replaces the Dart isolate in
/// `duplicate_finder_service.dart`.
pub fn scan_duplicates_stream(
    req: ScanRequest,
    op_id: String,
    sink: StreamSink<ScanEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result = dedupe::scan_duplicates(req, &cancel, move |p| {
        let _ = progress_sink.add(ScanEvent::Progress(p));
    });
    end(&op_id);

    let groups = result?;
    let _ = sink.add(ScanEvent::Done(groups));
    Ok(())
}

// ── file operations ────────────────────────────────────────────────────────

/// Progress or completion for a copy/move.
#[derive(Clone, Debug)]
pub enum OpEvent {
    Progress(OpProgress),
    Done(OpOutcome),
}

/// Files and bytes under `paths`, for sizing a progress bar before starting.
pub fn measure_paths(paths: Vec<String>) -> Vec<u64> {
    let (files, bytes) = fileops::measure(paths, &CancelToken::new());
    vec![files, bytes]
}

/// Copies `sources` into `dest_dir`, streaming progress.
pub fn copy_paths_stream(
    sources: Vec<String>,
    dest_dir: String,
    collision: Collision,
    op_id: String,
    sink: StreamSink<OpEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result = fileops::copy_paths(sources, dest_dir, collision, &cancel, move |p| {
        let _ = progress_sink.add(OpEvent::Progress(p));
    });
    end(&op_id);

    let outcome = result?;
    let _ = sink.add(OpEvent::Done(outcome));
    Ok(())
}

/// Moves `sources` into `dest_dir`, streaming progress. Uses `rename(2)` where
/// possible and falls back to copy-then-delete across filesystems.
pub fn move_paths_stream(
    sources: Vec<String>,
    dest_dir: String,
    collision: Collision,
    op_id: String,
    sink: StreamSink<OpEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result = fileops::move_paths(sources, dest_dir, collision, &cancel, move |p| {
        let _ = progress_sink.add(OpEvent::Progress(p));
    });
    end(&op_id);

    let outcome = result?;
    let _ = sink.add(OpEvent::Done(outcome));
    Ok(())
}

pub fn create_file(dir: String, name: String) -> Result<String, String> {
    fileops::create_file(dir, name)
}

pub fn create_dir(dir: String, name: String) -> Result<String, String> {
    fileops::create_dir(dir, name)
}

pub fn rename_path(path: String, new_name: String) -> Result<String, String> {
    fileops::rename_path(path, new_name)
}

// ── trash ──────────────────────────────────────────────────────────────────

/// Moves everything to the platform recycle bin — a real Recycle Bin on
/// Windows and an XDG trash on Linux, where the Dart code used to hard-delete.
pub fn move_to_trash(paths: Vec<String>) -> TrashOutcome {
    trash::move_to_trash(paths)
}

/// Permanently deletes. The UI must confirm before calling this.
pub fn delete_permanently(paths: Vec<String>) -> TrashOutcome {
    trash::delete_permanently(paths)
}

// ── quick actions ──────────────────────────────────────────────────────────

/// Progress or completion for a Quick Action that writes files.
#[derive(Clone, Debug)]
pub enum QuickEvent {
    Progress(QuickProgress),
    Done(QuickOutcome),
}

/// Progress or completion for a folder-size walk. Separate from [`QuickEvent`]
/// because the payload it finishes with is a measurement, not a list of
/// produced paths.
#[derive(Clone, Debug)]
pub enum StatsEvent {
    Progress(QuickProgress),
    Done(FolderStats),
}

/// Zips `sources` into `dest_dir/archive_name`, streaming progress.
pub fn compress_paths_stream(
    sources: Vec<String>,
    dest_dir: String,
    archive_name: String,
    op_id: String,
    sink: StreamSink<QuickEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result = quick::compress_paths(sources, dest_dir, archive_name, &cancel, move |p| {
        let _ = progress_sink.add(QuickEvent::Progress(p));
    });
    end(&op_id);

    let outcome = result?;
    let _ = sink.add(QuickEvent::Done(outcome));
    Ok(())
}

/// Unpacks an archive into `dest_dir`, streaming progress. With
/// `into_subfolder` the contents land in a new folder named after the archive.
pub fn extract_archive_stream(
    path: String,
    dest_dir: String,
    into_subfolder: bool,
    op_id: String,
    sink: StreamSink<QuickEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result =
        quick::extract_archive(path, dest_dir, into_subfolder, &cancel, move |p| {
            let _ = progress_sink.add(QuickEvent::Progress(p));
        });
    end(&op_id);

    let outcome = result?;
    let _ = sink.add(QuickEvent::Done(outcome));
    Ok(())
}

/// Walks a folder and reports what it actually holds. Cancellable, because a
/// home directory can take a while and the user may change their mind.
pub fn folder_stats_stream(
    path: String,
    op_id: String,
    sink: StreamSink<StatsEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let progress_sink = sink.clone();
    let result = quick::folder_stats(path, &cancel, move |p| {
        let _ = progress_sink.add(StatsEvent::Progress(p));
    });
    end(&op_id);

    let stats = result?;
    let _ = sink.add(StatsEvent::Done(stats));
    Ok(())
}

/// Re-encodes an image into `dest_dir`, optionally fitting it inside a
/// `max_dim` box. Returns the path written. The original is left alone.
pub fn convert_image(
    src: String,
    dest_dir: String,
    format: ImageTarget,
    max_dim: Option<u32>,
    quality: u8,
) -> Result<String, String> {
    quick::convert_image(src, dest_dir, format, max_dim, quality)
}

/// Rotates or flips an image, in place or into a suffixed sibling. Returns the
/// path written.
pub fn transform_image(
    src: String,
    transform: ImageTransform,
    in_place: bool,
) -> Result<String, String> {
    quick::transform_image(src, transform, in_place)
}

// ── search ─────────────────────────────────────────────────────────────────

/// A streamed search result, or the final summary.
#[derive(Clone, Debug)]
pub enum SearchEvent {
    Hit(SearchHit),
    Done(SearchSummary),
}

/// Streams filename (and optionally content) matches as they are found.
pub fn search_files_stream(
    req: SearchRequest,
    op_id: String,
    sink: StreamSink<SearchEvent>,
) -> Result<(), String> {
    let cancel = begin(&op_id);
    let hit_sink = sink.clone();
    let result = search::search_files(req, &cancel, move |hit| {
        let _ = hit_sink.add(SearchEvent::Hit(hit));
    });
    end(&op_id);

    let summary = result?;
    let _ = sink.add(SearchEvent::Done(summary));
    Ok(())
}

// ── listing, hashing, archives, thumbnails ─────────────────────────────────

/// One directory, pre-sorted. Replaces `file_service.dart:listDirectory`.
pub fn list_dir(path: String, sort: SortSpec) -> Result<Vec<DirEntryInfo>, String> {
    listing::list_dir(path, sort)
}

pub fn hash_file(path: String) -> Result<String, String> {
    hashing::hash_file(path)
}

pub fn hash_file_prefix(path: String, window: u64) -> Result<String, String> {
    hashing::hash_file_prefix(path, window)
}

/// Lists an archive's entries. For a zip this reads the central directory
/// only — no inflate, no loading the file into memory.
pub fn list_archive(path: String) -> Result<Vec<archive::ArchiveEntry>, String> {
    archive::list_archive(path)
}

pub fn extract_archive_entry(path: String, entry_name: String) -> Result<Vec<u8>, String> {
    archive::extract_archive_entry(path, entry_name)
}

pub fn thumbnail_image(
    src: String,
    dst: String,
    max_dim: u32,
) -> Result<ThumbnailInfo, String> {
    thumbnail::thumbnail_image(src, dst, max_dim)
}

/// Stable cache filename for a thumbnail, matching the Dart FNV-1a scheme so
/// the existing on-disk cache stays valid.
pub fn thumbnail_cache_key(
    path: String,
    modified_ms: i64,
    size: u64,
    dim: u32,
) -> String {
    thumbnail::cache_key(path, modified_ms, size, dim)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_registry_round_trips() {
        let token = begin("op-1");
        assert!(!token.is_cancelled());
        assert!(cancel_op("op-1".into()));
        assert!(token.is_cancelled(), "the registered token must be flipped");
        end("op-1");
        assert!(!cancel_op("op-1".into()), "a finished op is no longer cancellable");
    }

    #[test]
    fn cancelling_an_unknown_op_is_harmless() {
        assert!(!cancel_op("never-registered".into()));
    }

    #[test]
    fn ids_are_independent() {
        let a = begin("op-a");
        let b = begin("op-b");
        cancel_op("op-a".into());
        assert!(a.is_cancelled());
        assert!(!b.is_cancelled(), "cancelling one op must not affect another");
        end("op-a");
        end("op-b");
    }
}

// ── mail files ─────────────────────────────────────────────────────────────

/// Parses a `.eml` or `.msg` into headers, bodies and an attachment list.
///
/// The attachments come back as descriptions only. Their bytes are fetched one
/// at a time through [`read_email_attachment_bytes`], so opening a message with
/// a 40 MB deck in it doesn't move 40 MB into Dart before anything is shown.
pub fn read_email_message(path: String) -> Result<EmailMessageInfo, String> {
    email::read_email(path)
}

/// The bytes of one attachment, addressed by its index in the parsed message.
pub fn read_email_attachment_bytes(
    path: String,
    index: u32,
) -> Result<EmailAttachmentData, String> {
    email::read_email_attachment(path, index)
}

/// Writes one attachment into `dest_dir`, returning the path it was given.
pub fn save_email_attachment_to(
    path: String,
    index: u32,
    dest_dir: String,
) -> Result<String, String> {
    email::save_email_attachment(path, index, dest_dir)
}

// ── file sharing: the server ───────────────────────────────────────────────

/// Starts the SMB server and streams what it does.
///
/// The sink is held for the server's lifetime, so the Dart stream stays open
/// until [`smb_server_stop`] — closing it early would leave the UI blind to
/// clients connecting.
pub fn smb_server_start(
    settings: SmbServerSettings,
    sink: StreamSink<SmbServerEvent>,
) -> Result<u16, String> {
    sharing::start_server(
        settings,
        std::sync::Arc::new(move |event| {
            let _ = sink.add(event);
        }),
    )
}

/// Stops the server. False when nothing was running.
pub fn smb_server_stop() -> bool {
    sharing::stop_server()
}

pub fn smb_server_status() -> SmbServerStatus {
    sharing::server_status()
}

// ── file sharing: the client ───────────────────────────────────────────────

/// Opens a session against a share and keeps it for later calls.
pub fn smb_client_connect(settings: SmbClientSettings) -> Result<SmbSession, String> {
    sharing::client_connect(settings)
}

/// Checks credentials without keeping a session, returning the dialect that
/// was negotiated.
pub fn smb_client_probe(settings: SmbClientSettings) -> Result<String, String> {
    sharing::client_probe(settings)
}

pub fn smb_client_disconnect(session_id: String) -> bool {
    sharing::client_disconnect(session_id)
}

pub fn smb_client_list(session_id: String, path: String) -> Result<Vec<SmbEntry>, String> {
    sharing::client_list(session_id, path)
}

pub fn smb_client_stat(
    session_id: String,
    path: String,
) -> Result<Option<SmbEntry>, String> {
    sharing::client_stat(session_id, path)
}

/// Opens a file for reading or writing, returning a handle scoped to the
/// session.
pub fn smb_client_open(
    session_id: String,
    path: String,
    write: bool,
    truncate: bool,
) -> Result<SmbOpenFile, String> {
    sharing::client_open(session_id, path, write, truncate)
}

/// Reads at most `length` bytes. An empty result means end of file.
pub fn smb_client_read(
    session_id: String,
    handle: u64,
    offset: u64,
    length: u32,
) -> Result<Vec<u8>, String> {
    sharing::client_read(session_id, handle, offset, length)
}

/// Writes at `offset`, returning how many bytes the server accepted — which
/// may be fewer than were offered.
pub fn smb_client_write(
    session_id: String,
    handle: u64,
    offset: u64,
    data: Vec<u8>,
) -> Result<u32, String> {
    sharing::client_write(session_id, handle, offset, data)
}

pub fn smb_client_close(session_id: String, handle: u64) -> Result<(), String> {
    sharing::client_close(session_id, handle)
}

pub fn smb_client_create_directory(
    session_id: String,
    path: String,
) -> Result<(), String> {
    sharing::client_create_directory(session_id, path)
}

pub fn smb_client_delete(
    session_id: String,
    path: String,
    is_dir: bool,
) -> Result<(), String> {
    sharing::client_delete(session_id, path, is_dir)
}

pub fn smb_client_rename(
    session_id: String,
    from: String,
    to: String,
    replace: bool,
) -> Result<(), String> {
    sharing::client_rename(session_id, from, to, replace)
}

/// Copies a file inside one share, server-side where the server supports it.
pub fn smb_client_copy(
    session_id: String,
    from: String,
    to: String,
) -> Result<u64, String> {
    sharing::client_copy(session_id, from, to)
}

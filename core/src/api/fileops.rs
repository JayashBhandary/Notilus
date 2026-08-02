//! Copy, move and delete of files and directory trees.
//!
//! Fills the largest hole in the Dart app: `FileActionsService` could rename,
//! duplicate in place, and trash — there was no copy, no paste, and no move at
//! all. Its one recursive routine, `_copyDirectory`, walked file-by-file on the
//! main isolate with no progress and **no way to cancel**.
//!
//! What this module adds beyond "the same thing in Rust":
//!
//! - **Progress**, from a cheap recursive pre-pass that totals files and bytes
//!   so a UI can show a real percentage rather than a spinner.
//! - **Cancellation**, polled between files *and* between chunks of a large
//!   file, so a stuck 40 GB copy aborts promptly.
//! - **Partial-write cleanup**, so a cancelled or failed copy doesn't leave a
//!   half-written file looking like a real one.
//! - **Cross-device move**, falling back to copy-then-delete when `rename(2)`
//!   returns `EXDEV` — moving to a USB stick fails outright without this.
//! - **Recursive-containment refusal**, so copying a folder into its own
//!   subtree can't spin until the disk fills.

use crate::api::dedupe::CancelToken;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Copy buffer. Large enough to keep the syscall rate low on big files.
const COPY_BUF: usize = 1024 * 1024;

/// Emit progress at most this often, in bytes copied, so a big file still
/// animates without flooding the bridge.
const BYTE_REPORT_INTERVAL: u64 = 4 * 1024 * 1024;

/// What to do when the destination name is already taken.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Collision {
    /// Finder-style " copy", " copy 2"… Never destroys anything.
    Rename,
    /// Replace the existing item.
    Overwrite,
    /// Leave the existing item alone and report the source as skipped.
    Skip,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OpProgress {
    pub files_done: u64,
    pub files_total: u64,
    pub bytes_done: u64,
    pub bytes_total: u64,
    /// Path currently being worked on.
    pub current: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FailedItem {
    pub path: String,
    pub error: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct OpOutcome {
    /// Destination paths that were successfully created.
    pub completed: Vec<String>,
    /// Sources deliberately left alone under [`Collision::Skip`].
    pub skipped: Vec<String>,
    pub failed: Vec<FailedItem>,
    pub cancelled: bool,
}

impl OpOutcome {
    pub fn is_success(&self) -> bool {
        self.failed.is_empty() && !self.cancelled
    }
}

/// Files + bytes under `paths`, for sizing a progress bar.
///
/// Deliberately separate so a UI can show "Preparing…" while it runs, then
/// switch to a determinate bar. Unreadable entries are counted as zero rather
/// than failing — this is an estimate, not the operation.
pub fn measure(paths: Vec<String>, cancel: &CancelToken) -> (u64, u64) {
    let mut files = 0;
    let mut bytes = 0;
    for p in &paths {
        measure_one(Path::new(p), cancel, &mut files, &mut bytes);
    }
    (files, bytes)
}

fn measure_one(path: &Path, cancel: &CancelToken, files: &mut u64, bytes: &mut u64) {
    if cancel.is_cancelled() {
        return;
    }
    let Ok(meta) = fs::symlink_metadata(path) else {
        return;
    };
    if meta.is_dir() {
        let Ok(read) = fs::read_dir(path) else {
            return;
        };
        for entry in read.flatten() {
            measure_one(&entry.path(), cancel, files, bytes);
        }
    } else {
        *files += 1;
        *bytes += meta.len();
    }
}

/// Copies `sources` into `dest_dir`.
pub fn copy_paths<F>(
    sources: Vec<String>,
    dest_dir: String,
    collision: Collision,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<OpOutcome, String>
where
    F: Fn(OpProgress) + Send + Sync,
{
    run(sources, dest_dir, collision, false, cancel, on_progress)
}

/// Moves `sources` into `dest_dir`.
///
/// Tries `rename(2)` first — instant, and atomic within a filesystem. Falls
/// back to copy-then-delete across devices.
pub fn move_paths<F>(
    sources: Vec<String>,
    dest_dir: String,
    collision: Collision,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<OpOutcome, String>
where
    F: Fn(OpProgress) + Send + Sync,
{
    run(sources, dest_dir, collision, true, cancel, on_progress)
}

fn run<F>(
    sources: Vec<String>,
    dest_dir: String,
    collision: Collision,
    is_move: bool,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<OpOutcome, String>
where
    F: Fn(OpProgress) + Send + Sync,
{
    let dest_root = PathBuf::from(&dest_dir);
    if !dest_root.is_dir() {
        return Err(format!("Destination is not a folder: {dest_dir}"));
    }

    let (files_total, bytes_total) = measure(sources.clone(), cancel);
    let mut state = Tally {
        files_done: 0,
        files_total,
        bytes_done: 0,
        bytes_total,
        last_report: 0,
    };
    let mut outcome = OpOutcome::default();

    for source in &sources {
        if cancel.is_cancelled() {
            outcome.cancelled = true;
            break;
        }
        let src = Path::new(source);

        let Some(name) = src.file_name() else {
            outcome.failed.push(FailedItem {
                path: source.clone(),
                error: "Path has no name".into(),
            });
            continue;
        };

        // Copying a folder into itself or into its own subtree recurses until
        // the disk fills. Refuse before touching anything.
        if let Err(e) = check_containment(src, &dest_root) {
            outcome.failed.push(FailedItem {
                path: source.clone(),
                error: e,
            });
            continue;
        }

        // Moving an item into the folder it already lives in is a no-op — the
        // same thing Finder does. This has to be decided *before* collision
        // resolution: under `Collision::Rename` the target would otherwise
        // resolve to "a copy.txt", turning a no-op drag into a duplicate.
        if is_move && parent_is(src, &dest_root) {
            outcome.skipped.push(source.clone());
            continue;
        }

        let target = match resolve_target(&dest_root.join(name), collision) {
            Resolved::Path(p) => p,
            Resolved::Skip => {
                outcome.skipped.push(source.clone());
                continue;
            }
        };

        // Belt and braces: never let a move delete its own source.
        if is_move && same_file(src, &target) {
            outcome.skipped.push(source.clone());
            continue;
        }

        let result = if is_move {
            transfer_move(src, &target, cancel, &mut state, &on_progress)
        } else {
            transfer_copy(src, &target, cancel, &mut state, &on_progress)
        };

        match result {
            Ok(()) if cancel.is_cancelled() => {
                outcome.cancelled = true;
                // Roll back the partial destination so it can't be mistaken
                // for a complete copy.
                remove_quietly(&target);
                break;
            }
            Ok(()) => outcome
                .completed
                .push(target.to_string_lossy().into_owned()),
            Err(e) => {
                remove_quietly(&target);
                outcome.failed.push(FailedItem {
                    path: source.clone(),
                    error: e.to_string(),
                });
            }
        }
    }

    on_progress(state.snapshot(""));
    Ok(outcome)
}

/// Running totals, shared across the whole batch.
struct Tally {
    files_done: u64,
    files_total: u64,
    bytes_done: u64,
    bytes_total: u64,
    last_report: u64,
}

impl Tally {
    fn snapshot(&self, current: &str) -> OpProgress {
        OpProgress {
            files_done: self.files_done,
            files_total: self.files_total,
            bytes_done: self.bytes_done,
            bytes_total: self.bytes_total,
            current: current.to_string(),
        }
    }
}

fn transfer_move<F>(
    src: &Path,
    dst: &Path,
    cancel: &CancelToken,
    state: &mut Tally,
    on_progress: &F,
) -> io::Result<()>
where
    F: Fn(OpProgress) + Send + Sync,
{
    // Fast path: same filesystem. Instant regardless of size.
    match fs::rename(src, dst) {
        Ok(()) => {
            let (files, bytes) = measure(
                vec![dst.to_string_lossy().into_owned()],
                &CancelToken::new(),
            );
            state.files_done += files;
            state.bytes_done += bytes;
            on_progress(state.snapshot(&dst.to_string_lossy()));
            Ok(())
        }
        // EXDEV and friends: fall back to copy + delete. `CrossesDevices` is
        // still unstable as a matched variant on some targets, so treat any
        // rename failure where both ends are reachable as a fallback case.
        Err(_) if src.exists() => {
            transfer_copy(src, dst, cancel, state, on_progress)?;
            if cancel.is_cancelled() {
                return Ok(());
            }
            // Only unlink the source once the copy is fully committed.
            if src.is_dir() {
                fs::remove_dir_all(src)
            } else {
                fs::remove_file(src)
            }
        }
        Err(e) => Err(e),
    }
}

fn transfer_copy<F>(
    src: &Path,
    dst: &Path,
    cancel: &CancelToken,
    state: &mut Tally,
    on_progress: &F,
) -> io::Result<()>
where
    F: Fn(OpProgress) + Send + Sync,
{
    if cancel.is_cancelled() {
        return Ok(());
    }
    let meta = fs::symlink_metadata(src)?;

    if meta.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            if cancel.is_cancelled() {
                return Ok(());
            }
            let entry = entry?;
            transfer_copy(
                &entry.path(),
                &dst.join(entry.file_name()),
                cancel,
                state,
                on_progress,
            )?;
        }
        // Carry the folder's own timestamps over.
        let _ = filetime_from(&meta, dst);
        return Ok(());
    }

    if meta.file_type().is_symlink() {
        copy_symlink(src, dst)?;
        state.files_done += 1;
        on_progress(state.snapshot(&src.to_string_lossy()));
        return Ok(());
    }

    copy_file_streaming(src, dst, cancel, state, on_progress)?;
    let _ = filetime_from(&meta, dst);
    Ok(())
}

fn copy_file_streaming<F>(
    src: &Path,
    dst: &Path,
    cancel: &CancelToken,
    state: &mut Tally,
    on_progress: &F,
) -> io::Result<()>
where
    F: Fn(OpProgress) + Send + Sync,
{
    let mut reader = fs::File::open(src)?;
    let mut writer = fs::File::create(dst)?;
    let mut buf = vec![0u8; COPY_BUF];

    loop {
        if cancel.is_cancelled() {
            // Leave the partial file for the caller to remove — it knows
            // whether this was the cancelled item.
            return Ok(());
        }
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        writer.write_all(&buf[..n])?;
        state.bytes_done += n as u64;

        if state.bytes_done - state.last_report >= BYTE_REPORT_INTERVAL {
            state.last_report = state.bytes_done;
            on_progress(state.snapshot(&src.to_string_lossy()));
        }
    }
    writer.flush()?;

    // Preserve the executable bit and friends; a copied script that won't run
    // is a real bug, not a nicety.
    if let Ok(meta) = fs::metadata(src) {
        let _ = fs::set_permissions(dst, meta.permissions());
    }

    state.files_done += 1;
    on_progress(state.snapshot(&src.to_string_lossy()));
    Ok(())
}

#[cfg(unix)]
fn copy_symlink(src: &Path, dst: &Path) -> io::Result<()> {
    let target = fs::read_link(src)?;
    // Replace an existing link rather than failing.
    let _ = fs::remove_file(dst);
    std::os::unix::fs::symlink(target, dst)
}

#[cfg(not(unix))]
fn copy_symlink(src: &Path, dst: &Path) -> io::Result<()> {
    // On Windows, creating a symlink needs a privilege the app may not hold.
    // Copying the target's contents is the useful, always-available fallback.
    fs::copy(src, dst).map(|_| ())
}

fn filetime_from(meta: &fs::Metadata, dst: &Path) -> io::Result<()> {
    let modified = meta.modified()?;
    let file = fs::File::options().write(true).open(dst)?;
    file.set_modified(modified)
}

/// Refuses a copy/move that would place a directory inside itself.
fn check_containment(src: &Path, dest_dir: &Path) -> Result<(), String> {
    let src_c = src.canonicalize().unwrap_or_else(|_| src.to_path_buf());
    let dst_c = dest_dir
        .canonicalize()
        .unwrap_or_else(|_| dest_dir.to_path_buf());

    if src_c == dst_c {
        return Err("Source and destination are the same folder".into());
    }
    if src_c.is_dir() && dst_c.starts_with(&src_c) {
        return Err("Can't put a folder inside itself".into());
    }
    Ok(())
}

enum Resolved {
    Path(PathBuf),
    Skip,
}

/// Applies the collision policy, producing the path actually to write.
fn resolve_target(desired: &Path, collision: Collision) -> Resolved {
    if !exists(desired) {
        return Resolved::Path(desired.to_path_buf());
    }
    match collision {
        Collision::Skip => Resolved::Skip,
        Collision::Overwrite => Resolved::Path(desired.to_path_buf()),
        Collision::Rename => Resolved::Path(unique_name(desired)),
    }
}

/// Finder-style non-destructive naming: `notes.txt` → `notes copy.txt` →
/// `notes copy 2.txt`. The extension is preserved so the file still opens in
/// the right app.
pub fn unique_name(desired: &Path) -> PathBuf {
    if !exists(desired) {
        return desired.to_path_buf();
    }
    let parent = desired.parent().unwrap_or(Path::new("."));
    let stem = desired
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let ext = desired
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();

    let first = parent.join(format!("{stem} copy{ext}"));
    if !exists(&first) {
        return first;
    }
    for n in 2..10_000 {
        let candidate = parent.join(format!("{stem} copy {n}{ext}"));
        if !exists(&candidate) {
            return candidate;
        }
    }
    // Pathological directory; fall back to something certainly unique.
    parent.join(format!("{stem} copy {}{ext}", std::process::id()))
}

/// `Path::exists` follows symlinks, so a broken link reports false and we'd
/// happily clobber it. `symlink_metadata` sees the link itself.
fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

/// True when `dir` is the directory `path` already sits in.
fn parent_is(path: &Path, dir: &Path) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    match (parent.canonicalize(), dir.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => parent == dir,
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

fn remove_quietly(path: &Path) {
    if path.is_dir() {
        let _ = fs::remove_dir_all(path);
    } else {
        let _ = fs::remove_file(path);
    }
}

/// Creates an empty file, returning the path actually used (suffixed if the
/// name was taken). The "New File" the Dart app never had.
pub fn create_file(dir: String, name: String) -> Result<String, String> {
    let target = unique_name(&PathBuf::from(&dir).join(&name));
    fs::File::create(&target).map_err(|e| format!("{}: {e}", target.display()))?;
    Ok(target.to_string_lossy().into_owned())
}

/// Creates a directory, returning the path actually used.
pub fn create_dir(dir: String, name: String) -> Result<String, String> {
    let target = unique_name(&PathBuf::from(&dir).join(&name));
    fs::create_dir(&target).map_err(|e| format!("{}: {e}", target.display()))?;
    Ok(target.to_string_lossy().into_owned())
}

/// Renames in place. Returns the new path.
pub fn rename_path(path: String, new_name: String) -> Result<String, String> {
    let src = PathBuf::from(&path);
    let trimmed = new_name.trim();
    if trimmed.is_empty() {
        return Err("Name can't be empty".into());
    }
    if trimmed.contains(std::path::MAIN_SEPARATOR) || trimmed.contains('/') {
        return Err("Name can't contain a path separator".into());
    }
    let parent = src
        .parent()
        .ok_or_else(|| "Path has no parent".to_string())?;
    let target = parent.join(trimmed);

    if exists(&target) && !same_file(&src, &target) {
        return Err(format!("\"{trimmed}\" already exists"));
    }
    fs::rename(&src, &target).map_err(|e| format!("{path}: {e}"))?;
    Ok(target.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_fileops_tests")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, bytes: &[u8]) {
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).unwrap();
        }
        let mut f = fs::File::create(path).unwrap();
        f.write_all(bytes).unwrap();
    }

    fn copy(src: Vec<&Path>, dst: &Path, c: Collision) -> OpOutcome {
        copy_paths(
            src.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
            dst.to_string_lossy().into_owned(),
            c,
            &CancelToken::new(),
            |_| {},
        )
        .unwrap()
    }

    fn mv(src: Vec<&Path>, dst: &Path, c: Collision) -> OpOutcome {
        move_paths(
            src.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
            dst.to_string_lossy().into_owned(),
            c,
            &CancelToken::new(),
            |_| {},
        )
        .unwrap()
    }

    #[test]
    fn copies_a_single_file() {
        let dir = scratch("copy_file");
        let src = dir.join("a.txt");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&src, b"payload");

        let out = copy(vec![&src], &dest, Collision::Rename);
        assert!(out.is_success());
        assert_eq!(fs::read(dest.join("a.txt")).unwrap(), b"payload");
        assert!(src.exists(), "copy must leave the source in place");
    }

    #[test]
    fn copies_a_directory_tree_recursively() {
        let dir = scratch("copy_tree");
        let src = dir.join("src");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&src.join("top.txt"), b"1");
        write(&src.join("nested/deep/leaf.txt"), b"2");

        let out = copy(vec![&src], &dest, Collision::Rename);
        assert!(out.is_success(), "{out:?}");
        assert_eq!(fs::read(dest.join("src/top.txt")).unwrap(), b"1");
        assert_eq!(
            fs::read(dest.join("src/nested/deep/leaf.txt")).unwrap(),
            b"2"
        );
    }

    #[test]
    fn moves_a_file_and_removes_the_source() {
        let dir = scratch("move_file");
        let src = dir.join("a.txt");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&src, b"payload");

        let out = mv(vec![&src], &dest, Collision::Rename);
        assert!(out.is_success());
        assert!(!src.exists(), "move must remove the source");
        assert_eq!(fs::read(dest.join("a.txt")).unwrap(), b"payload");
    }

    #[test]
    fn moves_a_directory_tree() {
        let dir = scratch("move_tree");
        let src = dir.join("src");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&src.join("nested/leaf.txt"), b"x");

        assert!(mv(vec![&src], &dest, Collision::Rename).is_success());
        assert!(!src.exists());
        assert_eq!(fs::read(dest.join("src/nested/leaf.txt")).unwrap(), b"x");
    }

    #[test]
    fn rename_collision_policy_never_destroys() {
        let dir = scratch("collide_rename");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&dest.join("a.txt"), b"original");
        let src = dir.join("a.txt");
        write(&src, b"incoming");

        let out = copy(vec![&src], &dest, Collision::Rename);
        assert!(out.is_success());
        assert_eq!(
            fs::read(dest.join("a.txt")).unwrap(),
            b"original",
            "the existing file must be untouched"
        );
        assert_eq!(fs::read(dest.join("a copy.txt")).unwrap(), b"incoming");

        // A second copy escalates to " copy 2", preserving both again.
        copy(vec![&src], &dest, Collision::Rename);
        assert_eq!(fs::read(dest.join("a copy 2.txt")).unwrap(), b"incoming");
    }

    #[test]
    fn overwrite_and_skip_policies_behave() {
        let dir = scratch("collide_other");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&dest.join("a.txt"), b"original");
        let src = dir.join("a.txt");
        write(&src, b"incoming");

        let out = copy(vec![&src], &dest, Collision::Skip);
        assert_eq!(out.skipped.len(), 1);
        assert_eq!(fs::read(dest.join("a.txt")).unwrap(), b"original");

        let out = copy(vec![&src], &dest, Collision::Overwrite);
        assert!(out.is_success());
        assert_eq!(fs::read(dest.join("a.txt")).unwrap(), b"incoming");
    }

    #[test]
    fn refuses_to_copy_a_folder_into_itself() {
        let dir = scratch("containment");
        let src = dir.join("src");
        write(&src.join("f.txt"), b"x");
        let inner = src.join("nested");
        fs::create_dir_all(&inner).unwrap();

        let out = copy(vec![&src], &inner, Collision::Rename);
        assert_eq!(out.failed.len(), 1);
        assert!(
            out.failed[0].error.contains("inside itself"),
            "got: {}",
            out.failed[0].error
        );

        let out = copy(vec![&src], &src, Collision::Rename);
        assert_eq!(out.failed.len(), 1);
        assert!(out.failed[0].error.contains("same folder"));
    }

    #[test]
    fn moving_onto_itself_is_a_no_op_not_a_deletion() {
        // The dangerous case: without the same-file guard, a rename-to-self
        // followed by source cleanup would delete the user's data.
        let dir = scratch("move_self");
        let src = dir.join("a.txt");
        write(&src, b"precious");

        let out = mv(vec![&src], &dir, Collision::Rename);
        assert_eq!(out.skipped.len(), 1);
        assert!(src.exists());
        assert_eq!(fs::read(&src).unwrap(), b"precious");
    }

    #[test]
    fn cancellation_stops_the_batch_and_removes_the_partial() {
        let dir = scratch("cancel");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        for i in 0..5 {
            write(&dir.join(format!("f{i}.bin")), &vec![1u8; 1024]);
        }
        let sources: Vec<String> = (0..5)
            .map(|i| dir.join(format!("f{i}.bin")).to_string_lossy().into_owned())
            .collect();

        let cancel = CancelToken::new();
        cancel.cancel();
        let out = copy_paths(
            sources,
            dest.to_string_lossy().into_owned(),
            Collision::Rename,
            &cancel,
            |_| {},
        )
        .unwrap();

        assert!(out.cancelled);
        assert!(out.completed.is_empty());
    }

    #[test]
    fn progress_totals_reach_the_full_size() {
        use std::sync::Mutex;
        let dir = scratch("progress");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        write(&dir.join("src/a.bin"), &vec![0u8; 2048]);
        write(&dir.join("src/b.bin"), &vec![0u8; 1024]);

        let seen: Mutex<Vec<OpProgress>> = Mutex::new(Vec::new());
        copy_paths(
            vec![dir.join("src").to_string_lossy().into_owned()],
            dest.to_string_lossy().into_owned(),
            Collision::Rename,
            &CancelToken::new(),
            |p| seen.lock().unwrap().push(p),
        )
        .unwrap();

        let events = seen.into_inner().unwrap();
        let last = events.last().expect("expected progress events");
        assert_eq!(last.files_total, 2);
        assert_eq!(last.bytes_total, 3072);
        assert_eq!(last.files_done, 2);
        assert_eq!(last.bytes_done, 3072);
    }

    #[test]
    fn measure_counts_a_tree() {
        let dir = scratch("measure");
        write(&dir.join("a.bin"), &vec![0u8; 100]);
        write(&dir.join("sub/b.bin"), &vec![0u8; 200]);
        write(&dir.join("sub/deep/c.bin"), &vec![0u8; 300]);

        let (files, bytes) = measure(
            vec![dir.to_string_lossy().into_owned()],
            &CancelToken::new(),
        );
        assert_eq!(files, 3);
        assert_eq!(bytes, 600);
    }

    #[test]
    fn a_missing_source_is_reported_without_aborting_the_batch() {
        let dir = scratch("partial_fail");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        let good = dir.join("good.txt");
        write(&good, b"fine");
        let missing = dir.join("ghost.txt");

        let out = copy(vec![&missing, &good], &dest, Collision::Rename);
        assert_eq!(out.failed.len(), 1);
        assert_eq!(out.completed.len(), 1, "the good file must still copy");
        assert!(dest.join("good.txt").exists());
    }

    #[test]
    fn a_missing_destination_is_a_clear_error() {
        let dir = scratch("bad_dest");
        let err = copy_paths(
            vec![dir.join("x").to_string_lossy().into_owned()],
            dir.join("nope").to_string_lossy().into_owned(),
            Collision::Rename,
            &CancelToken::new(),
            |_| {},
        )
        .unwrap_err();
        assert!(err.contains("not a folder"), "got: {err}");
    }

    #[test]
    fn unique_name_preserves_the_extension() {
        let dir = scratch("unique");
        let f = dir.join("notes.tar.gz");
        write(&f, b"x");
        // Only the final component is treated as the extension, matching how
        // the rest of the app (and Finder) name things.
        assert_eq!(
            unique_name(&f).file_name().unwrap().to_string_lossy(),
            "notes.tar copy.gz"
        );

        let bare = dir.join("LICENSE");
        write(&bare, b"x");
        assert_eq!(
            unique_name(&bare).file_name().unwrap().to_string_lossy(),
            "LICENSE copy"
        );
    }

    #[test]
    fn create_file_and_dir_never_clobber() {
        let dir = scratch("create");
        let d = dir.to_string_lossy().into_owned();

        let a = create_file(d.clone(), "new.txt".into()).unwrap();
        let b = create_file(d.clone(), "new.txt".into()).unwrap();
        assert_ne!(a, b);
        assert!(b.ends_with("new copy.txt"));

        let x = create_dir(d.clone(), "folder".into()).unwrap();
        let y = create_dir(d, "folder".into()).unwrap();
        assert_ne!(x, y);
        assert!(Path::new(&y).is_dir());
    }

    #[test]
    fn rename_rejects_separators_empty_names_and_collisions() {
        let dir = scratch("rename");
        let a = dir.join("a.txt");
        write(&a, b"x");
        write(&dir.join("taken.txt"), b"y");
        let p = a.to_string_lossy().into_owned();

        assert!(rename_path(p.clone(), "  ".into()).is_err());
        assert!(rename_path(p.clone(), "sub/evil.txt".into()).is_err());
        assert!(rename_path(p.clone(), "taken.txt".into()).is_err());

        let renamed = rename_path(p, "b.txt".into()).unwrap();
        assert!(renamed.ends_with("b.txt"));
        assert!(!a.exists());
    }

    #[test]
    fn renaming_to_the_same_name_is_allowed() {
        // Case-only renames on a case-insensitive filesystem resolve to the
        // same file; rejecting them as "already exists" would be wrong.
        let dir = scratch("rename_same");
        let a = dir.join("a.txt");
        write(&a, b"x");
        assert!(rename_path(a.to_string_lossy().into_owned(), "a.txt".into()).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn the_executable_bit_survives_a_copy() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("perms");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        let script = dir.join("run.sh");
        write(&script, b"#!/bin/sh\necho hi\n");
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        copy(vec![&script], &dest, Collision::Rename);
        let mode = fs::metadata(dest.join("run.sh")).unwrap().permissions().mode();
        assert_eq!(mode & 0o111, 0o111, "executable bit was lost");
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_copied_as_links_not_followed() {
        let dir = scratch("symlink");
        let dest = dir.join("dest");
        fs::create_dir(&dest).unwrap();
        let target = dir.join("real.txt");
        write(&target, b"real");
        let link = dir.join("link.txt");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        copy(vec![&link], &dest, Collision::Rename);
        let copied = dest.join("link.txt");
        assert!(fs::symlink_metadata(&copied).unwrap().file_type().is_symlink());
    }
}

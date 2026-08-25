//! Duplicate file detection.
//!
//! Replaces `duplicate_finder_service.dart`, which was already isolated off
//! the UI thread but ran single-threaded end to end. Four things change here:
//!
//! 1. **The walk is parallel.** Dart recursed one directory at a time, and
//!    materialised every directory's children into a list before looking at
//!    any of them.
//! 2. **Hashing is parallel.** Dart hashed candidates strictly one after
//!    another, so a scan never used more than one core.
//! 3. **There is a prefix pass.** Before reading any file end to end, size
//!    collisions are separated by a head+tail fingerprint. Most collisions die
//!    after a few KB. Dart read every candidate in full.
//! 4. **Hardlinks are collapsed.** Dart de-duplicated by path string, so the
//!    same inode reached through two roots — or through a hardlink — was
//!    reported as a duplicate the user could not actually reclaim by deleting.
//!
//! The staged pipeline is the same one the Dart code documented: bucket by
//! size, then hash only what collides. Correctness rests on the final full
//! hash; the size and prefix passes only decide what is *worth* hashing.

use crate::api::hashing::{sha256_file, sha256_head_tail};
use crate::api::listing::{to_unix_millis, DirEntryInfo};
use ignore::{WalkBuilder, WalkState};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;

/// Files at or below this size skip the prefix pass — reading them twice costs
/// more than reading them once.
const PREHASH_MIN_SIZE: u64 = 64 * 1024;

/// Bytes taken from each end during the prefix pass.
const PREHASH_WINDOW: u64 = 4096;

/// Emit a progress event every this many files, so the Dart side isn't woken
/// once per file on a million-file scan.
const WALK_REPORT_EVERY: u64 = 200;
const HASH_REPORT_EVERY: u64 = 20;

/// Directories skipped wholesale: pseudo-filesystems, VM/swap, and mount roots
/// that would otherwise cause redundant or runaway crawls.
const SKIP_PREFIXES: &[&str] = &[
    "/proc",
    "/sys",
    "/dev",
    "/run",
    "/System/Volumes",
    "/private/var/vm",
    "/.Spotlight-V100",
    "/.fseventsd",
    "/.Trashes",
];

/// Trash / Recycle Bin directories, skipped regardless of the other toggles —
/// already-deleted files shouldn't resurface as duplicates.
const ALWAYS_SKIP_DIR_NAMES: &[&str] = &[
    "$recycle.bin",
    "recycler",
    ".trash",
    ".trashes",
    "trash",
    // Notilus's own thumbnails, which live beside the data on shared sources.
    // Two folders holding the same photo legitimately hold the same thumbnail,
    // and reporting those as duplicates the user could delete would be both
    // useless and destructive.
    ".thumbs",
];

/// macOS package directories: folders the OS presents as one opaque item.
/// Descending into them surfaces shared frameworks as "duplicates" the user
/// can't delete without breaking the app.
const BUNDLE_EXTS: &[&str] = &[
    ".app", ".framework", ".bundle", ".plugin", ".kext", ".xpc", ".appex",
    ".systemextension", ".qlgenerator", ".prefpane", ".component",
    ".mdimporter", ".wdgt", ".rtfd", ".download", ".photoslibrary",
    ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle",
    ".aplibrary", ".pkpass",
];

/// Dependency / build / cache directories that almost never hold user files
/// worth de-duplicating, and which balloon scan time.
pub const DEFAULT_EXCLUDED_DIRS: &[&str] = &[
    "node_modules", ".git", ".svn", ".hg", "venv", ".venv", "__pycache__",
    "site-packages", ".tox", ".mypy_cache", ".pytest_cache", "build", "dist",
    "target", ".gradle", ".dart_tool", ".next", ".nuxt", ".parcel-cache",
    "pods", "carthage", "deriveddata", "vendor", "bower_components", ".cache",
    ".terraform", ".cargo",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScanRequest {
    pub roots: Vec<String>,
    /// Files smaller than this are ignored entirely.
    pub min_size: u64,
    /// Lowercase directory basenames to prune.
    pub excluded_dir_names: Vec<String>,
    /// Lowercase extensions including the leading dot. `None` means every file.
    pub allowed_extensions: Option<Vec<String>>,
    pub skip_hidden: bool,
    pub skip_bundles: bool,
}

impl Default for ScanRequest {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            min_size: 1,
            excluded_dir_names: Vec::new(),
            allowed_extensions: None,
            skip_hidden: true,
            skip_bundles: true,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScanPhase {
    /// Walking the tree.
    Scanning,
    /// Fingerprinting and hashing size collisions.
    Comparing,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScanProgress {
    pub phase: ScanPhase,
    pub files_seen: u64,
    pub files_hashed: u64,
    pub hash_total: u64,
    pub current_path: String,
}

/// A set of files with identical size and content hash — byte-for-byte
/// duplicates. Mirrors Dart's `DuplicateGroup`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DuplicateGroup {
    pub hash: String,
    pub size: u64,
    pub files: Vec<DirEntryInfo>,
}

impl DuplicateGroup {
    /// Space reclaimable by keeping a single copy.
    pub fn reclaimable_bytes(&self) -> u64 {
        self.size * (self.files.len() as u64 - 1)
    }
}

/// Cooperative cancellation. Cheap to clone; every stage polls it, so a
/// cancelled scan unwinds at the next file rather than running to completion.
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

/// Runs a full duplicate scan.
///
/// `on_progress` is called from worker threads, so it must be `Sync`; the
/// bridge shim forwards it to a `StreamSink`. Returns groups ordered by
/// reclaimable bytes, largest first. A cancelled scan returns `Ok(vec![])`.
pub fn scan_duplicates<F>(
    req: ScanRequest,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<Vec<DuplicateGroup>, String>
where
    F: Fn(ScanProgress) + Send + Sync,
{
    if req.roots.is_empty() {
        return Ok(Vec::new());
    }

    let files = walk(&req, cancel, &on_progress)?;
    if cancel.is_cancelled() {
        return Ok(Vec::new());
    }
    let files_seen = files.len() as u64;

    // Pass 1 — bucket by exact size. Files of different sizes cannot match.
    let candidates = collide_by(files, |f| f.size.to_string());
    if candidates.is_empty() || cancel.is_cancelled() {
        return Ok(Vec::new());
    }

    // Pass 2 — head+tail fingerprint, but only where it can pay for itself.
    let (prehash_worthy, small): (Vec<_>, Vec<_>) = candidates
        .into_iter()
        .partition(|f| f.size > PREHASH_MIN_SIZE);

    let mut candidates = small;
    if !prehash_worthy.is_empty() {
        let fingerprinted = hash_all(
            prehash_worthy,
            cancel,
            |path| sha256_head_tail(path, PREHASH_WINDOW).ok(),
            |_, _| {}, // silent: the prefix pass is short, progress starts below
        );
        candidates.extend(collide_by(fingerprinted, |(_, fp)| fp.clone()).into_iter().map(|(f, _)| f));
    }
    if candidates.is_empty() || cancel.is_cancelled() {
        return Ok(Vec::new());
    }

    // Pass 3 — full hash. Only survivors of both earlier passes get here.
    let hash_total = candidates.len() as u64;
    let hashed = hash_all(
        candidates,
        cancel,
        |path| sha256_file(path).ok(),
        |done, path| {
            if done.is_multiple_of(HASH_REPORT_EVERY) || done == hash_total {
                on_progress(ScanProgress {
                    phase: ScanPhase::Comparing,
                    files_seen,
                    files_hashed: done,
                    hash_total,
                    current_path: path.to_string(),
                });
            }
        },
    );
    if cancel.is_cancelled() {
        return Ok(Vec::new());
    }

    Ok(group(hashed))
}

/// Parallel filesystem walk honouring every filter in [`ScanRequest`].
fn walk<F>(
    req: &ScanRequest,
    cancel: &CancelToken,
    on_progress: &F,
) -> Result<Vec<DirEntryInfo>, String>
where
    F: Fn(ScanProgress) + Send + Sync,
{
    let excluded: Vec<String> = req.excluded_dir_names.iter().map(|s| s.to_lowercase()).collect();
    let allowed: Option<Vec<String>> = req
        .allowed_extensions
        .as_ref()
        .map(|v| v.iter().map(|s| s.to_lowercase()).collect());

    let skip_hidden = req.skip_hidden;
    let skip_bundles = req.skip_bundles;

    let mut builder = WalkBuilder::new(&req.roots[0]);
    for root in &req.roots[1..] {
        builder.add(root);
    }
    builder
        // We apply our own rules; gitignore/hidden handling from `ignore`
        // would silently drop user files.
        .standard_filters(false)
        .follow_links(false)
        .same_file_system(false)
        .threads(rayon::current_num_threads().max(1));

    {
        let excluded = excluded.clone();
        builder.filter_entry(move |entry| {
            let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
            if !is_dir {
                return true; // file-level rules are applied in the visitor
            }
            let path = entry.path();
            // Depth 0 is a root the user explicitly chose — never prune it.
            if entry.depth() == 0 {
                return true;
            }
            if is_skipped_prefix(path) {
                return false;
            }
            let Some(name) = path.file_name() else {
                return true;
            };
            let lower = name.to_string_lossy().to_lowercase();
            if is_trash_dir(&lower) {
                return false;
            }
            if skip_bundles && is_bundle_dir(&lower) {
                return false;
            }
            if skip_hidden && lower.starts_with('.') {
                return false;
            }
            !excluded.contains(&lower)
        });
    }

    let seen = AtomicU64::new(0);
    // Shared by reference into the per-thread visitors; `&T` is Copy, so the
    // `move` closures below copy the borrow rather than trying to take the
    // atomic itself.
    let seen = &seen;
    let min_size = req.min_size;
    let (tx, rx) = mpsc::channel::<DirEntryInfo>();

    builder.build_parallel().run(|| {
        let tx = tx.clone();
        let allowed = allowed.clone();
        Box::new(move |result| {
            if cancel.is_cancelled() {
                return WalkState::Quit;
            }
            // A permission-denied or vanished entry is skipped quietly, the
            // same tolerance the Dart walk had.
            let Ok(entry) = result else {
                return WalkState::Continue;
            };
            if !entry.file_type().is_some_and(|t| t.is_file()) {
                return WalkState::Continue;
            }

            let path = entry.path();
            let name = match path.file_name() {
                Some(n) => n.to_string_lossy().into_owned(),
                None => return WalkState::Continue,
            };
            if skip_hidden && name.starts_with('.') {
                return WalkState::Continue;
            }
            if let Some(exts) = &allowed {
                let ext = match path.extension() {
                    Some(e) => format!(".{}", e.to_string_lossy().to_lowercase()),
                    None => String::new(),
                };
                if !exts.contains(&ext) {
                    return WalkState::Continue;
                }
            }
            let Ok(meta) = entry.metadata() else {
                return WalkState::Continue;
            };
            if meta.len() < min_size {
                return WalkState::Continue;
            }

            let count = seen.fetch_add(1, Ordering::Relaxed) + 1;
            let info = DirEntryInfo {
                path: path.to_string_lossy().into_owned(),
                name,
                is_dir: false,
                size: meta.len(),
                modified_ms: meta.modified().map(to_unix_millis).unwrap_or(0),
            };
            if count.is_multiple_of(WALK_REPORT_EVERY) {
                on_progress(ScanProgress {
                    phase: ScanPhase::Scanning,
                    files_seen: count,
                    files_hashed: 0,
                    hash_total: 0,
                    current_path: info.path.clone(),
                });
            }
            let _ = tx.send(info);
            WalkState::Continue
        })
    });

    drop(tx);
    let mut files: Vec<DirEntryInfo> = rx.into_iter().collect();
    dedupe_same_inode(&mut files);
    Ok(files)
}

/// Collapses entries that are the same file on disk — reached via overlapping
/// roots, or genuinely hardlinked. Deleting one of those does not reclaim
/// anything, so reporting them as duplicates would be a lie.
fn dedupe_same_inode(files: &mut Vec<DirEntryInfo>) {
    #[cfg(unix)]
    {
        use std::collections::HashSet;
        use std::os::unix::fs::MetadataExt;
        let mut seen: HashSet<(u64, u64)> = HashSet::new();
        files.retain(|f| match std::fs::metadata(&f.path) {
            Ok(m) => seen.insert((m.dev(), m.ino())),
            // Unreadable now: keep it and let the hash stage drop it.
            Err(_) => true,
        });
    }
    #[cfg(not(unix))]
    {
        use std::collections::HashSet;
        let mut seen: HashSet<String> = HashSet::new();
        files.retain(|f| seen.insert(f.path.to_lowercase()));
    }
}

/// Keeps only the items whose key is shared by at least one other item.
fn collide_by<T, K, F>(items: Vec<T>, key: F) -> Vec<T>
where
    F: Fn(&T) -> K,
    K: std::hash::Hash + Eq,
{
    let mut counts: HashMap<K, usize> = HashMap::new();
    for item in &items {
        *counts.entry(key(item)).or_insert(0) += 1;
    }
    items
        .into_iter()
        .filter(|item| counts.get(&key(item)).copied().unwrap_or(0) > 1)
        .collect()
}

/// Hashes `files` in parallel with `hasher`, dropping anything unreadable.
/// `report` is called with the running count and the path just finished.
fn hash_all<H, R>(
    files: Vec<DirEntryInfo>,
    cancel: &CancelToken,
    hasher: H,
    report: R,
) -> Vec<(DirEntryInfo, String)>
where
    H: Fn(&Path) -> Option<String> + Send + Sync,
    R: Fn(u64, &str) + Send + Sync,
{
    let done = AtomicU64::new(0);
    files
        .into_par_iter()
        .filter_map(|file| {
            if cancel.is_cancelled() {
                return None;
            }
            let hash = hasher(Path::new(&file.path))?;
            let count = done.fetch_add(1, Ordering::Relaxed) + 1;
            report(count, &file.path);
            Some((file, hash))
        })
        .collect()
}

/// Buckets hashed files into groups, ordered by reclaimable space.
fn group(hashed: Vec<(DirEntryInfo, String)>) -> Vec<DuplicateGroup> {
    // Key on size *and* hash, guarding against a theoretical hash collision
    // between differently-sized files.
    let mut buckets: HashMap<(u64, String), Vec<DirEntryInfo>> = HashMap::new();
    for (file, hash) in hashed {
        buckets.entry((file.size, hash)).or_default().push(file);
    }

    let mut groups: Vec<DuplicateGroup> = buckets
        .into_iter()
        .filter(|(_, files)| files.len() > 1)
        .map(|((size, hash), mut files)| {
            files.sort_by_key(|f| f.path.to_lowercase());
            DuplicateGroup { hash, size, files }
        })
        .collect();

    groups.sort_by(|a, b| {
        b.reclaimable_bytes()
            .cmp(&a.reclaimable_bytes())
            // Stable, deterministic output for equal savings — tests and the
            // on-disk scan cache both depend on a fixed order.
            .then_with(|| a.files[0].path.cmp(&b.files[0].path))
    });
    groups
}

fn is_skipped_prefix(path: &Path) -> bool {
    let s = path.to_string_lossy();
    SKIP_PREFIXES
        .iter()
        .any(|p| s == *p || s.starts_with(&format!("{p}/")))
}

fn is_trash_dir(lower_name: &str) -> bool {
    ALWAYS_SKIP_DIR_NAMES.contains(&lower_name) || lower_name.starts_with(".trash-")
}

fn is_bundle_dir(lower_name: &str) -> bool {
    BUNDLE_EXTS
        .iter()
        .any(|ext| lower_name.ends_with(ext) && lower_name.len() > ext.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_dedupe_tests")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let mut f = fs::File::create(path).unwrap();
        f.write_all(bytes).unwrap();
    }

    fn scan(dir: &Path, req: ScanRequest) -> Vec<DuplicateGroup> {
        let req = ScanRequest {
            roots: vec![dir.to_string_lossy().into_owned()],
            ..req
        };
        scan_duplicates(req, &CancelToken::new(), |_| {}).unwrap()
    }

    #[test]
    fn finds_identical_files_and_ignores_unique_ones() {
        let dir = scratch("basic");
        write(&dir.join("a.txt"), b"same content here");
        write(&dir.join("nested/b.txt"), b"same content here");
        write(&dir.join("c.txt"), b"different entirely");

        let groups = scan(&dir, ScanRequest::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].files.len(), 2);
        let names: Vec<_> = groups[0].files.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"a.txt") && names.contains(&"b.txt"));
    }

    #[test]
    fn same_size_but_different_content_is_not_a_duplicate() {
        // The size bucket collides; only the hash can separate these.
        let dir = scratch("samesize");
        write(&dir.join("x.bin"), b"AAAAAAAAAA");
        write(&dir.join("y.bin"), b"BBBBBBBBBB");
        assert!(scan(&dir, ScanRequest::default()).is_empty());
    }

    #[test]
    fn large_files_differing_only_in_the_middle_survive_the_prefix_pass() {
        // Regression guard: the head+tail fingerprint must never be the final
        // word. These two share size, head and tail, and differ only mid-file.
        let dir = scratch("midfile");
        let mut a = vec![42u8; (PREHASH_MIN_SIZE * 3) as usize];
        let mut b = a.clone();
        let middle = a.len() / 2;
        a[middle] = 1;
        b[middle] = 2;
        write(&dir.join("a.bin"), &a);
        write(&dir.join("b.bin"), &b);

        assert!(
            scan(&dir, ScanRequest::default()).is_empty(),
            "prefix pass wrongly promoted a mid-file difference to a duplicate"
        );

        // And the same files, when genuinely identical, are still found.
        write(&dir.join("b.bin"), &a);
        let groups = scan(&dir, ScanRequest::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].files.len(), 2);
    }

    #[test]
    fn groups_are_ordered_by_reclaimable_space() {
        let dir = scratch("ordering");
        write(&dir.join("small_1"), b"aa");
        write(&dir.join("small_2"), b"aa");
        let big = vec![9u8; 5000];
        write(&dir.join("big_1"), &big);
        write(&dir.join("big_2"), &big);

        let groups = scan(&dir, ScanRequest::default());
        assert_eq!(groups.len(), 2);
        assert!(groups[0].reclaimable_bytes() > groups[1].reclaimable_bytes());
        assert_eq!(groups[0].size, 5000);
    }

    #[test]
    fn excluded_directories_are_pruned() {
        let dir = scratch("excludes");
        write(&dir.join("keep.txt"), b"dup");
        write(&dir.join("node_modules/skip.txt"), b"dup");

        let groups = scan(
            &dir,
            ScanRequest {
                excluded_dir_names: vec!["node_modules".into()],
                ..ScanRequest::default()
            },
        );
        assert!(groups.is_empty(), "node_modules should have been pruned");

        // Without the exclusion the pair is found, proving the files matched.
        let groups = scan(&dir, ScanRequest::default());
        assert_eq!(groups.len(), 1);
    }

    #[test]
    fn hidden_files_and_folders_respect_the_toggle() {
        let dir = scratch("hidden");
        write(&dir.join("visible.txt"), b"dup");
        write(&dir.join(".hidden.txt"), b"dup");

        assert!(scan(&dir, ScanRequest::default()).is_empty());

        let groups = scan(
            &dir,
            ScanRequest {
                skip_hidden: false,
                ..ScanRequest::default()
            },
        );
        assert_eq!(groups.len(), 1);
    }

    #[test]
    fn bundle_directories_are_opaque_when_requested() {
        let dir = scratch("bundles");
        write(&dir.join("loose.txt"), b"dup");
        write(&dir.join("Thing.app/Contents/inner.txt"), b"dup");

        assert!(scan(&dir, ScanRequest::default()).is_empty());

        let groups = scan(
            &dir,
            ScanRequest {
                skip_bundles: false,
                ..ScanRequest::default()
            },
        );
        assert_eq!(groups.len(), 1);
    }

    #[test]
    fn min_size_filters_small_files() {
        let dir = scratch("minsize");
        write(&dir.join("tiny_1"), b"ab");
        write(&dir.join("tiny_2"), b"ab");

        assert!(scan(
            &dir,
            ScanRequest {
                min_size: 1024,
                ..ScanRequest::default()
            }
        )
        .is_empty());
        assert_eq!(scan(&dir, ScanRequest::default()).len(), 1);
    }

    #[test]
    fn extension_allowlist_restricts_candidates() {
        let dir = scratch("exts");
        write(&dir.join("a.jpg"), b"image bytes");
        write(&dir.join("b.jpg"), b"image bytes");
        write(&dir.join("a.txt"), b"text bytes!");
        write(&dir.join("b.txt"), b"text bytes!");

        let groups = scan(
            &dir,
            ScanRequest {
                allowed_extensions: Some(vec![".jpg".into()]),
                ..ScanRequest::default()
            },
        );
        assert_eq!(groups.len(), 1);
        assert!(groups[0].files.iter().all(|f| f.name.ends_with(".jpg")));
    }

    #[test]
    fn empty_files_are_excluded_by_the_default_min_size() {
        // Every empty file hashes identically; grouping them is noise.
        let dir = scratch("empty");
        write(&dir.join("e1"), b"");
        write(&dir.join("e2"), b"");
        assert!(scan(&dir, ScanRequest::default()).is_empty());
    }

    #[test]
    fn three_way_duplicates_land_in_one_group() {
        let dir = scratch("threeway");
        for n in ["one", "two", "three"] {
            write(&dir.join(n), b"identical payload");
        }
        let groups = scan(&dir, ScanRequest::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].files.len(), 3);
        assert_eq!(
            groups[0].reclaimable_bytes(),
            groups[0].size * 2,
            "keeping one copy reclaims the other two"
        );
    }

    #[test]
    fn results_are_sorted_deterministically_within_a_group() {
        let dir = scratch("determinism");
        for n in ["zeta", "alpha", "mid"] {
            write(&dir.join(n), b"stable ordering please");
        }
        let first = scan(&dir, ScanRequest::default());
        let second = scan(&dir, ScanRequest::default());
        let paths = |g: &[DuplicateGroup]| -> Vec<String> {
            g[0].files.iter().map(|f| f.name.clone()).collect()
        };
        assert_eq!(paths(&first), vec!["alpha", "mid", "zeta"]);
        assert_eq!(paths(&first), paths(&second));
    }

    #[cfg(unix)]
    #[test]
    fn hardlinks_are_not_reported_as_duplicates() {
        let dir = scratch("hardlinks");
        let original = dir.join("original.bin");
        write(&original, b"one inode, two names");
        fs::hard_link(&original, dir.join("link.bin")).unwrap();

        assert!(
            scan(&dir, ScanRequest::default()).is_empty(),
            "deleting a hardlink reclaims nothing, so it isn't a duplicate"
        );
    }

    #[test]
    fn overlapping_roots_do_not_duplicate_a_file_against_itself() {
        let dir = scratch("overlap");
        write(&dir.join("sub/only.txt"), b"just one real file");

        let req = ScanRequest {
            roots: vec![
                dir.to_string_lossy().into_owned(),
                dir.join("sub").to_string_lossy().into_owned(),
            ],
            ..ScanRequest::default()
        };
        let groups = scan_duplicates(req, &CancelToken::new(), |_| {}).unwrap();
        assert!(groups.is_empty());
    }

    #[test]
    fn a_cancelled_scan_returns_nothing() {
        let dir = scratch("cancel");
        write(&dir.join("a"), b"dup dup dup");
        write(&dir.join("b"), b"dup dup dup");

        let cancel = CancelToken::new();
        cancel.cancel();
        let req = ScanRequest {
            roots: vec![dir.to_string_lossy().into_owned()],
            ..ScanRequest::default()
        };
        assert!(scan_duplicates(req, &cancel, |_| {}).unwrap().is_empty());
    }

    #[test]
    fn progress_reaches_the_callback_during_hashing() {
        use std::sync::Mutex;
        let dir = scratch("progress");
        for i in 0..60 {
            write(&dir.join(format!("f{i}")), b"all the same content");
        }

        let seen: Mutex<Vec<ScanProgress>> = Mutex::new(Vec::new());
        let req = ScanRequest {
            roots: vec![dir.to_string_lossy().into_owned()],
            ..ScanRequest::default()
        };
        scan_duplicates(req, &CancelToken::new(), |p| {
            seen.lock().unwrap().push(p);
        })
        .unwrap();

        let events = seen.into_inner().unwrap();
        assert!(
            events.iter().any(|e| e.phase == ScanPhase::Comparing),
            "expected at least one Comparing progress event"
        );
        let last = events.last().unwrap();
        assert_eq!(last.files_hashed, last.hash_total);
    }

    #[test]
    fn no_roots_is_not_an_error() {
        let groups =
            scan_duplicates(ScanRequest::default(), &CancelToken::new(), |_| {}).unwrap();
        assert!(groups.is_empty());
    }

    #[test]
    fn a_missing_root_yields_no_results_rather_than_failing() {
        // Matches the Dart tolerance: an unreadable root is skipped quietly.
        let req = ScanRequest {
            roots: vec!["/definitely/not/here".into()],
            ..ScanRequest::default()
        };
        assert!(scan_duplicates(req, &CancelToken::new(), |_| {})
            .unwrap()
            .is_empty());
    }

    #[test]
    fn bundle_matching_does_not_swallow_a_folder_named_only_dot_app() {
        assert!(is_bundle_dir("safari.app"));
        assert!(!is_bundle_dir(".app"));
        assert!(!is_bundle_dir("myapp"));
    }

    #[test]
    fn trash_directories_are_recognised_across_platforms() {
        assert!(is_trash_dir(".trash"));
        assert!(is_trash_dir("$recycle.bin"));
        assert!(is_trash_dir(".trash-1000"));
        assert!(!is_trash_dir("trashcan"));
    }
}

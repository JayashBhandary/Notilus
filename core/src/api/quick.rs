//! Quick Actions — the one-click operations the file browser's context menu
//! offers on whatever is under the cursor.
//!
//! These are the jobs a file manager is asked for constantly and that every
//! pure-Dart implementation gets wrong in the same way: zipping a folder,
//! unpacking an archive, working out what a directory actually weighs, and
//! rotating or converting an image. All four are byte-shovelling loops, so
//! running them here keeps them off the UI isolate, gives them the same
//! cancellation and progress plumbing as copy/move, and lets them reuse the
//! collision-free naming in [`crate::api::fileops`] — no Quick Action ever
//! overwrites an existing file.
//!
//! Everything is *derivative*: a Quick Action writes a new file beside the
//! original (the one exception is an explicit in-place image rotate), so a
//! mistake costs disk space rather than data.

use crate::api::archive::{classify, inner_name, ArchiveKind};
use crate::api::dedupe::CancelToken;
use crate::api::fileops::{measure, unique_name, FailedItem};
use bzip2::read::BzDecoder;
use flate2::read::GzDecoder;
use image::imageops::FilterType;
use image::{ImageDecoder, ImageFormat, ImageReader};
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

/// Chunk size for the archive read/write loops. Matches `fileops::COPY_BUF`.
const IO_BUF: usize = 1024 * 1024;

/// Report progress at most this often, in bytes, so a multi-gigabyte archive
/// still animates without waking Dart thousands of times a second.
const BYTE_REPORT_INTERVAL: u64 = 4 * 1024 * 1024;

/// Entries between progress reports while measuring a directory tree — the
/// walk itself is far cheaper per item than an archive's per-byte work.
const WALK_REPORT_EVERY: u64 = 500;

/// Cap on a single extracted entry, mirroring the preview extractor's limit so
/// a zip bomb can't fill the disk from one click.
const MAX_ENTRY_BYTES: u64 = 8 * 1024 * 1024 * 1024;

// ── shared shapes ──────────────────────────────────────────────────────────

/// Progress for any streaming Quick Action.
///
/// Deliberately the same shape as `fileops::OpProgress`: the UI already has a
/// progress bar bound to those fields, and a second, subtly different struct
/// would mean a second bar. `*_total` is 0 when the total isn't knowable up
/// front — a tar has to be read to be counted — which the UI shows as an
/// indeterminate bar.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QuickProgress {
    pub files_done: u64,
    pub files_total: u64,
    pub bytes_done: u64,
    pub bytes_total: u64,
    /// The item being worked on, for the label under the bar.
    pub current: String,
}

impl QuickProgress {
    fn new(files_total: u64, bytes_total: u64) -> Self {
        Self {
            files_done: 0,
            files_total,
            bytes_done: 0,
            bytes_total,
            current: String::new(),
        }
    }
}

/// How a Quick Action ended.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct QuickOutcome {
    /// What was created — the archive path, the extraction root, the converted
    /// image. The UI selects `produced[0]` so the result is visible on return.
    pub produced: Vec<String>,
    /// Items that couldn't be handled. A single unreadable file never aborts
    /// the whole action; it lands here and the rest continues.
    pub failed: Vec<FailedItem>,
    pub cancelled: bool,
}

impl QuickOutcome {
    pub fn is_success(&self) -> bool {
        self.failed.is_empty() && !self.cancelled
    }
}

/// Emits a progress event, rate-limited by bytes so the caller can call this
/// as often as it likes.
struct Reporter<F: Fn(QuickProgress)> {
    sink: F,
    state: QuickProgress,
    last_reported_bytes: u64,
}

impl<F: Fn(QuickProgress)> Reporter<F> {
    fn new(sink: F, files_total: u64, bytes_total: u64) -> Self {
        Self {
            sink,
            state: QuickProgress::new(files_total, bytes_total),
            last_reported_bytes: 0,
        }
    }

    /// Called when work moves to a new item. Always emits: the filename under
    /// the bar is what tells the user the action is alive on small files.
    fn begin_item(&mut self, current: &str) {
        self.state.current = current.to_string();
        self.emit();
    }

    fn add_bytes(&mut self, n: u64) {
        self.state.bytes_done += n;
        if self.state.bytes_done - self.last_reported_bytes >= BYTE_REPORT_INTERVAL {
            self.emit();
        }
    }

    fn finish_item(&mut self) {
        self.state.files_done += 1;
    }

    fn emit(&mut self) {
        self.last_reported_bytes = self.state.bytes_done;
        (self.sink)(self.state.clone());
    }
}

fn failed(path: impl AsRef<Path>, error: impl ToString) -> FailedItem {
    FailedItem {
        path: path.as_ref().to_string_lossy().into_owned(),
        error: error.to_string(),
    }
}

// ── compress ───────────────────────────────────────────────────────────────

/// Zips `sources` into `dest_dir/archive_name`.
///
/// Names inside the archive are relative to each source's *parent*, so zipping
/// `~/Photos` produces `Photos/…` rather than a pile of loose files or an
/// absolute path — the layout every unzip tool and every user expects.
///
/// `archive_name` gains a `.zip` suffix if it lacks one, and collides
/// non-destructively: a second "Compress" on the same folder writes
/// `Photos copy.zip`, never over the first archive.
///
/// Directory symlinks are skipped rather than followed — a link pointing at an
/// ancestor would otherwise walk forever. File symlinks are stored as their
/// contents, which is what a portable zip can represent.
pub fn compress_paths<F>(
    sources: Vec<String>,
    dest_dir: String,
    archive_name: String,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<QuickOutcome, String>
where
    F: Fn(QuickProgress) + Send + Sync,
{
    if sources.is_empty() {
        return Err("Nothing to compress".into());
    }
    let dest_dir = PathBuf::from(&dest_dir);
    if !dest_dir.is_dir() {
        return Err(format!("{} is not a folder", dest_dir.display()));
    }

    let mut name = archive_name.trim().to_string();
    if name.is_empty() {
        return Err("The archive needs a name".into());
    }
    if !name.to_lowercase().ends_with(".zip") {
        name.push_str(".zip");
    }
    let target = unique_name(&dest_dir.join(name));

    // Sizing pass. It walks the tree a second time, but it is metadata-only —
    // cheap next to the deflate that follows — and it is what turns the bar
    // from a spinner into a real estimate.
    let (files_total, bytes_total) = measure(sources.clone(), cancel);
    let mut reporter = Reporter::new(on_progress, files_total, bytes_total);
    let mut outcome = QuickOutcome::default();

    let file = File::create(&target).map_err(|e| format!("{}: {e}", target.display()))?;
    let mut zip = zip::ZipWriter::new(BufWriter::new(file));

    for source in &sources {
        if cancel.is_cancelled() {
            break;
        }
        let src = PathBuf::from(source);
        // The archive root: everything is named relative to this, so the
        // source's own basename becomes the first path component.
        let base = src.parent().map(Path::to_path_buf).unwrap_or_default();

        let meta = match fs::symlink_metadata(&src) {
            Ok(m) => m,
            Err(e) => {
                outcome.failed.push(failed(&src, e));
                continue;
            }
        };

        if meta.is_dir() {
            add_tree(&mut zip, &src, &base, cancel, &mut reporter, &mut outcome);
        } else if let Err(e) = add_file(&mut zip, &src, &base, cancel, &mut reporter) {
            outcome.failed.push(failed(&src, e));
        }
    }

    // A cancelled archive is a truncated archive. Finish the stream so the
    // handle closes cleanly, then remove it — a half-written zip on disk
    // looks like a successful result until someone tries to open it.
    let cancelled = cancel.is_cancelled();
    let finish = zip.finish().map_err(|e| e.to_string());
    if cancelled {
        let _ = fs::remove_file(&target);
        outcome.cancelled = true;
        return Ok(outcome);
    }
    if let Err(e) = finish {
        let _ = fs::remove_file(&target);
        return Err(format!("{}: {e}", target.display()));
    }

    outcome.produced.push(target.to_string_lossy().into_owned());
    Ok(outcome)
}

fn zip_options(meta: Option<&fs::Metadata>) -> zip::write::SimpleFileOptions {
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        // Zip64 headers, so a single member over 4 GB doesn't silently wrap.
        .large_file(true);
    match meta {
        #[cfg(unix)]
        Some(m) => {
            use std::os::unix::fs::PermissionsExt;
            opts.unix_permissions(m.permissions().mode())
        }
        #[cfg(not(unix))]
        Some(_) => opts,
        None => opts,
    }
}

/// Walks `dir` depth-first, adding every entry under it.
///
/// Per-entry failures are recorded and skipped: one unreadable file in a
/// 10,000-file folder must not cost the user the other 9,999.
fn add_tree<W, F>(
    zip: &mut zip::ZipWriter<W>,
    dir: &Path,
    base: &Path,
    cancel: &CancelToken,
    reporter: &mut Reporter<F>,
    outcome: &mut QuickOutcome,
) where
    W: Write + io::Seek,
    F: Fn(QuickProgress),
{
    // `follow_links(false)`: a directory symlink pointing at an ancestor turns
    // the walk into an infinite one.
    let walk = WalkDir::new(dir).follow_links(false).into_iter();
    for entry in walk {
        if cancel.is_cancelled() {
            return;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                outcome.failed.push(failed(dir, e));
                continue;
            }
        };
        let path = entry.path();
        if entry.file_type().is_dir() {
            // Empty directories exist only as their own entry, so they have to
            // be written explicitly or they vanish from the archive.
            let name = zip_name(path, base);
            if let Err(e) = zip.add_directory(name, zip_options(None)) {
                outcome.failed.push(failed(path, e));
            }
            continue;
        }
        if entry.file_type().is_symlink() {
            continue;
        }
        if let Err(e) = add_file(zip, path, base, cancel, reporter) {
            outcome.failed.push(failed(path, e));
        }
    }
}

fn add_file<W, F>(
    zip: &mut zip::ZipWriter<W>,
    path: &Path,
    base: &Path,
    cancel: &CancelToken,
    reporter: &mut Reporter<F>,
) -> Result<(), String>
where
    W: Write + io::Seek,
    F: Fn(QuickProgress),
{
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    reporter.begin_item(&path.to_string_lossy());
    zip.start_file(zip_name(path, base), zip_options(Some(&meta)))
        .map_err(|e| e.to_string())?;

    let mut reader = BufReader::new(File::open(path).map_err(|e| e.to_string())?);
    let mut buf = vec![0u8; IO_BUF];
    loop {
        if cancel.is_cancelled() {
            return Ok(());
        }
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        zip.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        reporter.add_bytes(n as u64);
    }
    reporter.finish_item();
    Ok(())
}

/// The name an entry gets inside the archive: its path relative to `base`,
/// with forward slashes. Zip stores `/` on every platform, so a Windows-built
/// archive still unpacks correctly elsewhere.
fn zip_name(path: &Path, base: &Path) -> String {
    let rel = path.strip_prefix(base).unwrap_or(path);
    rel.to_string_lossy().replace('\\', "/")
}

// ── extract ────────────────────────────────────────────────────────────────

/// Unpacks the archive at `path`.
///
/// With `into_subfolder`, everything lands in a new folder named after the
/// archive — the safe default, because an archive that isn't rooted in a single
/// directory would otherwise spray dozens of files into the current folder.
///
/// Entry names are checked before anything is written: an entry naming `..`, an
/// absolute path, or a drive prefix is refused rather than followed. That is
/// the "zip slip" traversal, and it is the reason this doesn't call the zip
/// crate's own `extract`.
pub fn extract_archive<F>(
    path: String,
    dest_dir: String,
    into_subfolder: bool,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<QuickOutcome, String>
where
    F: Fn(QuickProgress) + Send + Sync,
{
    let src = PathBuf::from(&path);
    let kind = classify(&src)
        .ok_or_else(|| format!("{} isn't an archive Notilus can open", src.display()))?;

    let dest_dir = PathBuf::from(&dest_dir);
    if !dest_dir.is_dir() {
        return Err(format!("{} is not a folder", dest_dir.display()));
    }
    let root = if into_subfolder {
        unique_name(&dest_dir.join(archive_stem(&src)))
    } else {
        dest_dir.clone()
    };
    fs::create_dir_all(&root).map_err(|e| format!("{}: {e}", root.display()))?;

    let mut outcome = QuickOutcome::default();
    let result = match kind {
        ArchiveKind::Zip => extract_zip(&src, &root, cancel, on_progress, &mut outcome),
        ArchiveKind::Tar => extract_tar(
            tar::Archive::new(BufReader::new(open(&src)?)),
            &root,
            cancel,
            on_progress,
            &mut outcome,
        ),
        ArchiveKind::TarGz => extract_tar(
            tar::Archive::new(GzDecoder::new(BufReader::new(open(&src)?))),
            &root,
            cancel,
            on_progress,
            &mut outcome,
        ),
        ArchiveKind::TarBz2 => extract_tar(
            tar::Archive::new(BzDecoder::new(BufReader::new(open(&src)?))),
            &root,
            cancel,
            on_progress,
            &mut outcome,
        ),
        ArchiveKind::Gz => extract_single(
            &mut GzDecoder::new(BufReader::new(open(&src)?)),
            &root.join(inner_name(&src)),
            cancel,
            on_progress,
            &mut outcome,
        ),
        ArchiveKind::Bz2 => extract_single(
            &mut BzDecoder::new(BufReader::new(open(&src)?)),
            &root.join(inner_name(&src)),
            cancel,
            on_progress,
            &mut outcome,
        ),
    };
    result.map_err(|e| format!("Couldn't extract {}: {e}", src.display()))?;

    if cancel.is_cancelled() {
        outcome.cancelled = true;
        // Only a folder this call created is safe to remove. Extracting into
        // an existing folder mixes new files with the user's own, and no
        // bookkeeping here justifies deleting those.
        if into_subfolder {
            let _ = fs::remove_dir_all(&root);
        }
        return Ok(outcome);
    }

    outcome.produced.push(root.to_string_lossy().into_owned());
    Ok(outcome)
}

fn open(path: &Path) -> Result<File, String> {
    File::open(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// The folder name an archive unpacks into: its basename with every archive
/// suffix removed, so `photos.tar.gz` becomes `photos`, not `photos.tar`.
fn archive_stem(path: &Path) -> String {
    let name = path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "archive".to_string());
    let lower = name.to_lowercase();
    for suffix in [
        ".tar.gz", ".tar.bz2", ".tgz", ".tbz2", ".zip", ".jar", ".tar", ".gz", ".bz2",
    ] {
        if lower.ends_with(suffix) {
            return name[..name.len() - suffix.len()].to_string();
        }
    }
    name
}

fn extract_zip<F>(
    src: &Path,
    root: &Path,
    cancel: &CancelToken,
    on_progress: F,
    outcome: &mut QuickOutcome,
) -> Result<(), String>
where
    F: Fn(QuickProgress),
{
    let mut archive = zip::ZipArchive::new(BufReader::new(open(src)?))
        .map_err(|e| e.to_string())?;

    // The central directory carries every entry's uncompressed size, so a zip —
    // unlike a tar — can be sized without decompressing a byte.
    let mut files_total = 0u64;
    let mut bytes_total = 0u64;
    for i in 0..archive.len() {
        if let Ok(entry) = archive.by_index_raw(i) {
            if !entry.is_dir() {
                files_total += 1;
                bytes_total += entry.size();
            }
        }
    }
    let mut reporter = Reporter::new(on_progress, files_total, bytes_total);

    for i in 0..archive.len() {
        if cancel.is_cancelled() {
            return Ok(());
        }
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        // `enclosed_name` is None for anything that would escape the root.
        let Some(rel) = entry.enclosed_name() else {
            outcome
                .failed
                .push(failed(entry.name(), "unsafe entry name, skipped"));
            continue;
        };
        let Some(target) = safe_join(root, &rel) else {
            outcome
                .failed
                .push(failed(entry.name(), "unsafe entry name, skipped"));
            continue;
        };

        if entry.is_dir() {
            if let Err(e) = fs::create_dir_all(&target) {
                outcome.failed.push(failed(&target, e));
            }
            continue;
        }
        if entry.size() > MAX_ENTRY_BYTES {
            outcome
                .failed
                .push(failed(&target, "entry exceeds the extraction size limit"));
            continue;
        }
        if let Err(e) = write_entry(&mut entry, &target, cancel, &mut reporter) {
            outcome.failed.push(failed(&target, e));
        }
    }
    Ok(())
}

fn extract_tar<R, F>(
    mut archive: tar::Archive<R>,
    root: &Path,
    cancel: &CancelToken,
    on_progress: F,
    outcome: &mut QuickOutcome,
) -> Result<(), String>
where
    R: Read,
    F: Fn(QuickProgress),
{
    // A tar's headers are interleaved with its data, so nothing can be counted
    // without reading the whole stream. Totals stay 0 and the bar stays
    // indeterminate rather than lying about a percentage.
    let mut reporter = Reporter::new(on_progress, 0, 0);

    for entry in archive.entries().map_err(|e| e.to_string())? {
        if cancel.is_cancelled() {
            return Ok(());
        }
        let mut entry = entry.map_err(|e| e.to_string())?;
        let rel = entry.path().map_err(|e| e.to_string())?.into_owned();
        let Some(target) = safe_join(root, &rel) else {
            outcome
                .failed
                .push(failed(rel, "unsafe entry name, skipped"));
            continue;
        };

        if entry.header().entry_type().is_dir() {
            if let Err(e) = fs::create_dir_all(&target) {
                outcome.failed.push(failed(&target, e));
            }
            continue;
        }
        // Hardlinks and device nodes have no bytes to copy and no portable
        // meaning outside their original filesystem.
        if !entry.header().entry_type().is_file() {
            continue;
        }
        if let Err(e) = write_entry(&mut entry, &target, cancel, &mut reporter) {
            outcome.failed.push(failed(&target, e));
        }
    }
    Ok(())
}

/// A bare `.gz` / `.bz2` wraps exactly one payload and carries no entry table.
fn extract_single<R, F>(
    reader: &mut R,
    target: &Path,
    cancel: &CancelToken,
    on_progress: F,
    outcome: &mut QuickOutcome,
) -> Result<(), String>
where
    R: Read,
    F: Fn(QuickProgress),
{
    let mut reporter = Reporter::new(on_progress, 1, 0);
    if let Err(e) = write_entry(reader, target, cancel, &mut reporter) {
        outcome.failed.push(failed(target, e));
    }
    Ok(())
}

/// Streams one entry to disk, honouring cancellation between chunks.
///
/// A cancelled or failed write removes the partial file: a truncated document
/// that looks like a real one is worse than a missing one.
fn write_entry<R, F>(
    reader: &mut R,
    target: &Path,
    cancel: &CancelToken,
    reporter: &mut Reporter<F>,
) -> Result<(), String>
where
    R: Read,
    F: Fn(QuickProgress),
{
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    // Non-destructive by default, like every other write in this crate.
    let target = unique_name(target);
    reporter.begin_item(&target.to_string_lossy());

    let mut out = BufWriter::new(File::create(&target).map_err(|e| e.to_string())?);
    let mut buf = vec![0u8; IO_BUF];
    let mut written = 0u64;
    loop {
        if cancel.is_cancelled() {
            drop(out);
            let _ = fs::remove_file(&target);
            return Ok(());
        }
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                drop(out);
                let _ = fs::remove_file(&target);
                return Err(e.to_string());
            }
        };
        written += n as u64;
        if written > MAX_ENTRY_BYTES {
            drop(out);
            let _ = fs::remove_file(&target);
            return Err("entry exceeds the extraction size limit".into());
        }
        if let Err(e) = out.write_all(&buf[..n]) {
            drop(out);
            let _ = fs::remove_file(&target);
            return Err(e.to_string());
        }
        reporter.add_bytes(n as u64);
    }
    out.flush().map_err(|e| e.to_string())?;
    reporter.finish_item();
    Ok(())
}

/// Joins `rel` onto `root`, refusing anything that could escape it.
///
/// `enclosed_name` already screens zip entries; tar entries get no such check
/// from the tar crate, and both benefit from the belt-and-braces pass here.
fn safe_join(root: &Path, rel: &Path) -> Option<PathBuf> {
    let mut out = root.to_path_buf();
    for component in rel.components() {
        match component {
            Component::Normal(part) => out.push(part),
            // A leading `./` is harmless noise; everything else is an escape
            // attempt or a platform-specific root we must not honour.
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    // An entry naming only "." or "/" resolves back to the root itself.
    if out == root {
        return None;
    }
    Some(out)
}

// ── folder stats ───────────────────────────────────────────────────────────

/// What a folder actually contains, recursively.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FolderStats {
    pub path: String,
    pub files: u64,
    pub dirs: u64,
    /// Apparent size: the sum of file lengths, not blocks on disk.
    pub bytes: u64,
    /// The single biggest file under `path`, which is almost always the answer
    /// to the question that prompted the user to ask for the size at all.
    pub largest_path: String,
    pub largest_bytes: u64,
    /// Most recent mtime anywhere in the tree, in Unix milliseconds.
    pub newest_ms: i64,
    /// Entries that couldn't be read — usually permissions. Reported rather
    /// than hidden, because they make the total an undercount.
    pub unreadable: u64,
    pub cancelled: bool,
}

/// Walks `path` and totals it up.
///
/// The equivalent of Finder's "Calculate All Sizes": a folder's `stat` size is
/// the directory entry's own, never its contents, so the only way to answer
/// "how big is this?" is to walk it. Symlinks are counted as their own small
/// selves and never followed, so a link into `/` can't turn a folder's size
/// into the whole disk's.
pub fn folder_stats<F>(
    path: String,
    cancel: &CancelToken,
    on_progress: F,
) -> Result<FolderStats, String>
where
    F: Fn(QuickProgress) + Send + Sync,
{
    let root = PathBuf::from(&path);
    if !root.is_dir() {
        return Err(format!("{} is not a folder", root.display()));
    }

    let mut stats = FolderStats {
        path: path.clone(),
        ..Default::default()
    };
    // Totals are unknown until the walk ends — that is the whole point of the
    // walk — so the bar is a counter, not a percentage.
    let mut reporter = Reporter::new(on_progress, 0, 0);
    let mut seen = 0u64;

    for entry in WalkDir::new(&root).follow_links(false).min_depth(1) {
        if cancel.is_cancelled() {
            stats.cancelled = true;
            return Ok(stats);
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => {
                stats.unreadable += 1;
                continue;
            }
        };
        if entry.file_type().is_dir() {
            stats.dirs += 1;
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            stats.unreadable += 1;
            continue;
        };
        stats.files += 1;
        stats.bytes += meta.len();
        if meta.len() > stats.largest_bytes {
            stats.largest_bytes = meta.len();
            stats.largest_path = entry.path().to_string_lossy().into_owned();
        }
        if let Ok(modified) = meta.modified() {
            let ms = crate::api::listing::to_unix_millis(modified);
            if ms > stats.newest_ms {
                stats.newest_ms = ms;
            }
        }

        seen += 1;
        if seen.is_multiple_of(WALK_REPORT_EVERY) {
            reporter.state.files_done = stats.files;
            reporter.state.bytes_done = stats.bytes;
            reporter.begin_item(&entry.path().to_string_lossy());
        }
    }
    Ok(stats)
}

// ── image quick actions ────────────────────────────────────────────────────

/// The formats a Quick Action can write. Deliberately three: PNG for lossless,
/// JPEG for photos, WebP for the web. The `image` crate writes WebP losslessly
/// only, which is fine for the "make this shareable" job and honest about it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImageTarget {
    Png,
    Jpeg,
    WebP,
}

impl ImageTarget {
    fn extension(self) -> &'static str {
        match self {
            ImageTarget::Png => "png",
            ImageTarget::Jpeg => "jpg",
            ImageTarget::WebP => "webp",
        }
    }

    fn format(self) -> ImageFormat {
        match self {
            ImageTarget::Png => ImageFormat::Png,
            ImageTarget::Jpeg => ImageFormat::Jpeg,
            ImageTarget::WebP => ImageFormat::WebP,
        }
    }
}

/// A lossless, one-click reorientation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImageTransform {
    RotateLeft,
    RotateRight,
    Rotate180,
    FlipHorizontal,
    FlipVertical,
}

impl ImageTransform {
    /// The suffix a non-destructive result gets, so the new file says what
    /// happened to it.
    fn suffix(self) -> &'static str {
        match self {
            ImageTransform::RotateLeft => "rotated left",
            ImageTransform::RotateRight => "rotated right",
            ImageTransform::Rotate180 => "rotated 180",
            ImageTransform::FlipHorizontal => "flipped",
            ImageTransform::FlipVertical => "flipped vertical",
        }
    }
}

/// Re-encodes `src` into `dest_dir` as `format`, optionally fitting it inside
/// a `max_dim` box first.
///
/// Always writes a new file — converting is how you get a shareable copy, not
/// how you throw the original away. `quality` applies to JPEG only (1–100);
/// PNG and WebP here are lossless.
pub fn convert_image(
    src: String,
    dest_dir: String,
    format: ImageTarget,
    max_dim: Option<u32>,
    quality: u8,
) -> Result<String, String> {
    let src_path = PathBuf::from(&src);
    let dest_dir = PathBuf::from(&dest_dir);
    if !dest_dir.is_dir() {
        return Err(format!("{} is not a folder", dest_dir.display()));
    }

    let mut image = decode_upright(&src_path)?;
    if let Some(dim) = max_dim {
        if dim == 0 {
            return Err("The size limit must be greater than zero".into());
        }
        if image.width().max(image.height()) > dim {
            image = image.resize(dim, dim, FilterType::Lanczos3);
        }
    }

    let stem = src_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".into());
    let target = unique_name(&dest_dir.join(format!("{stem}.{}", format.extension())));
    write_image(&image, &target, format, quality)?;
    Ok(target.to_string_lossy().into_owned())
}

/// Rotates or flips `src`.
///
/// With `in_place` the original is replaced; otherwise a suffixed sibling is
/// written and the original is untouched. In-place still writes to a temporary
/// file first and renames over the original only once encoding succeeded, so a
/// failure part-way through can't leave a truncated image where a good one was.
pub fn transform_image(
    src: String,
    transform: ImageTransform,
    in_place: bool,
) -> Result<String, String> {
    let src_path = PathBuf::from(&src);
    let format = ImageFormat::from_path(&src_path)
        .map_err(|_| format!("Notilus can't write {} back out", src_path.display()))?;
    let target_kind = match format {
        ImageFormat::Png => ImageTarget::Png,
        ImageFormat::Jpeg => ImageTarget::Jpeg,
        ImageFormat::WebP => ImageTarget::WebP,
        // Reading GIF/TIFF/BMP works, but re-encoding them is either lossy in
        // a way the user didn't ask for (animation dropped) or unsupported.
        other => {
            return Err(format!(
                "Rotating a {} isn't supported — convert it first",
                format!("{other:?}").to_uppercase()
            ))
        }
    };

    let image = decode_upright(&src_path)?;
    let rotated = match transform {
        ImageTransform::RotateLeft => image.rotate270(),
        ImageTransform::RotateRight => image.rotate90(),
        ImageTransform::Rotate180 => image.rotate180(),
        ImageTransform::FlipHorizontal => image.fliph(),
        ImageTransform::FlipVertical => image.flipv(),
    };

    if !in_place {
        let parent = src_path.parent().unwrap_or(Path::new("."));
        let stem = src_path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "image".into());
        let ext = src_path
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_else(|| target_kind.extension().into());
        let target =
            unique_name(&parent.join(format!("{stem} {}.{ext}", transform.suffix())));
        write_image(&rotated, &target, target_kind, 92)?;
        return Ok(target.to_string_lossy().into_owned());
    }

    let temp = src_path.with_extension(format!(
        "{}.notilus-tmp",
        src_path
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_default()
    ));
    write_image(&rotated, &temp, target_kind, 92)?;
    fs::rename(&temp, &src_path).map_err(|e| {
        let _ = fs::remove_file(&temp);
        format!("{}: {e}", src_path.display())
    })?;
    Ok(src)
}

/// Decodes an image with its EXIF orientation already applied.
///
/// Phone JPEGs are almost always stored sideways with a tag saying which way
/// up they go. Rotating one without honouring the tag rotates from the wrong
/// starting point, and re-encoding drops the tag — so the result would look
/// doubly wrong.
fn decode_upright(path: &Path) -> Result<image::DynamicImage, String> {
    let reader = ImageReader::open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?
        .with_guessed_format()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let orientation = decoder
        .orientation()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let mut image = image::DynamicImage::from_decoder(decoder)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    image.apply_orientation(orientation);
    Ok(image)
}

fn write_image(
    image: &image::DynamicImage,
    target: &Path,
    format: ImageTarget,
    quality: u8,
) -> Result<(), String> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    match format {
        // JPEG is the one format whose quality is worth exposing, and
        // `save_with_format` gives no way to set it.
        ImageTarget::Jpeg => {
            let file = File::create(target).map_err(|e| format!("{}: {e}", target.display()))?;
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(
                BufWriter::new(file),
                quality.clamp(1, 100),
            );
            // JPEG has no alpha channel; encoding RGBA yields a garbled image.
            encoder
                .encode_image(&image::DynamicImage::ImageRgb8(image.to_rgb8()))
                .map_err(|e| format!("{}: {e}", target.display()))
        }
        _ => image
            .save_with_format(target, format.format())
            .map_err(|e| format!("{}: {e}", target.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_quick_tests")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(dir: &Path, name: &str, bytes: &[u8]) {
        let path = dir.join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, bytes).unwrap();
    }

    fn s(p: &Path) -> String {
        p.to_string_lossy().into_owned()
    }

    fn noop(_: QuickProgress) {}

    #[test]
    fn compresses_a_folder_rooted_at_its_own_name() {
        let dir = scratch("zip_folder");
        let src = dir.join("Photos");
        fs::create_dir_all(src.join("nested")).unwrap();
        write(&src, "a.txt", b"aaa");
        write(&src, "nested/b.txt", b"bbbb");

        let out = compress_paths(
            vec![s(&src)],
            s(&dir),
            "Photos".into(),
            &CancelToken::new(),
            noop,
        )
        .unwrap();
        assert!(out.is_success(), "{out:?}");

        let archive = PathBuf::from(&out.produced[0]);
        assert_eq!(archive.file_name().unwrap(), "Photos.zip");

        let names: Vec<_> = crate::api::archive::list_archive(s(&archive))
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert!(names.contains(&"Photos/a.txt".to_string()), "{names:?}");
        assert!(
            names.contains(&"Photos/nested/b.txt".to_string()),
            "{names:?}"
        );
    }

    #[test]
    fn a_second_compress_never_overwrites_the_first() {
        let dir = scratch("zip_collide");
        write(&dir, "notes.txt", b"hi");
        let src = s(&dir.join("notes.txt"));

        let first = compress_paths(
            vec![src.clone()],
            s(&dir),
            "notes.zip".into(),
            &CancelToken::new(),
            noop,
        )
        .unwrap();
        let second = compress_paths(
            vec![src],
            s(&dir),
            "notes.zip".into(),
            &CancelToken::new(),
            noop,
        )
        .unwrap();

        assert_ne!(first.produced[0], second.produced[0]);
        assert!(PathBuf::from(&first.produced[0]).exists());
        assert!(second.produced[0].contains("copy"), "{:?}", second.produced);
    }

    #[test]
    fn a_cancelled_compress_leaves_no_archive_behind() {
        let dir = scratch("zip_cancel");
        write(&dir, "a.bin", &[1u8; 4096]);
        let cancel = CancelToken::new();
        cancel.cancel();

        let out = compress_paths(
            vec![s(&dir.join("a.bin"))],
            s(&dir),
            "out.zip".into(),
            &cancel,
            noop,
        )
        .unwrap();
        assert!(out.cancelled);
        assert!(out.produced.is_empty());
        assert!(!dir.join("out.zip").exists(), "partial archive must be removed");
    }

    #[test]
    fn round_trips_a_zip_through_compress_and_extract() {
        let dir = scratch("round_trip");
        let src = dir.join("src");
        fs::create_dir_all(&src).unwrap();
        write(&src, "hello.txt", b"hello world");

        let zipped = compress_paths(
            vec![s(&src)],
            s(&dir),
            "src".into(),
            &CancelToken::new(),
            noop,
        )
        .unwrap();

        let dest = dir.join("out");
        fs::create_dir_all(&dest).unwrap();
        let out = extract_archive(
            zipped.produced[0].clone(),
            s(&dest),
            true,
            &CancelToken::new(),
            noop,
        )
        .unwrap();
        assert!(out.is_success(), "{out:?}");

        let root = PathBuf::from(&out.produced[0]);
        assert_eq!(root.file_name().unwrap(), "src");
        assert_eq!(
            fs::read_to_string(root.join("src/hello.txt")).unwrap(),
            "hello world"
        );
    }

    #[test]
    fn extracting_without_a_subfolder_writes_into_the_destination() {
        let dir = scratch("extract_flat");
        write(&dir, "one.txt", b"1");
        let zipped = compress_paths(
            vec![s(&dir.join("one.txt"))],
            s(&dir),
            "bundle".into(),
            &CancelToken::new(),
            noop,
        )
        .unwrap();

        let dest = dir.join("dest");
        fs::create_dir_all(&dest).unwrap();
        extract_archive(
            zipped.produced[0].clone(),
            s(&dest),
            false,
            &CancelToken::new(),
            noop,
        )
        .unwrap();
        assert!(dest.join("one.txt").exists());
    }

    #[test]
    fn a_traversing_entry_is_refused_rather_than_written() {
        let root = Path::new("/tmp/root");
        assert!(safe_join(root, Path::new("../evil.sh")).is_none());
        assert!(safe_join(root, Path::new("a/../../evil.sh")).is_none());
        assert!(safe_join(root, Path::new("/etc/passwd")).is_none());
        assert!(safe_join(root, Path::new(".")).is_none());
        assert_eq!(
            safe_join(root, Path::new("./docs/a.txt")),
            Some(PathBuf::from("/tmp/root/docs/a.txt"))
        );
    }

    #[test]
    fn archive_stem_drops_every_compound_suffix() {
        assert_eq!(archive_stem(Path::new("/x/photos.tar.gz")), "photos");
        assert_eq!(archive_stem(Path::new("/x/photos.tgz")), "photos");
        assert_eq!(archive_stem(Path::new("/x/photos.zip")), "photos");
        assert_eq!(archive_stem(Path::new("/x/photos.tar.bz2")), "photos");
        assert_eq!(archive_stem(Path::new("/x/photos")), "photos");
    }

    #[test]
    fn folder_stats_totals_the_whole_tree_and_names_the_biggest_file() {
        let dir = scratch("stats");
        write(&dir, "small.bin", &[0u8; 10]);
        write(&dir, "nested/deep/big.bin", &[0u8; 5000]);

        let stats = folder_stats(s(&dir), &CancelToken::new(), noop).unwrap();
        assert_eq!(stats.files, 2);
        assert_eq!(stats.dirs, 2, "nested + deep");
        assert_eq!(stats.bytes, 5010);
        assert_eq!(stats.largest_bytes, 5000);
        assert!(stats.largest_path.ends_with("big.bin"), "{stats:?}");
        assert!(!stats.cancelled);
    }

    #[test]
    fn folder_stats_on_a_file_is_an_error() {
        let dir = scratch("stats_file");
        write(&dir, "a.txt", b"x");
        assert!(folder_stats(s(&dir.join("a.txt")), &CancelToken::new(), noop).is_err());
    }

    fn write_png(path: &Path, w: u32, h: u32) {
        let mut img = RgbaImage::new(w, h);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = Rgba([(x % 256) as u8, (y % 256) as u8, 200, 255]);
        }
        img.save_with_format(path, ImageFormat::Png).unwrap();
    }

    #[test]
    fn converting_writes_a_sibling_and_leaves_the_original_alone() {
        let dir = scratch("convert");
        let src = dir.join("shot.png");
        write_png(&src, 300, 150);

        let out = convert_image(s(&src), s(&dir), ImageTarget::Jpeg, None, 85).unwrap();
        let out = PathBuf::from(out);
        assert_eq!(out.extension().unwrap(), "jpg");
        assert!(src.exists(), "the original must survive");
        assert_eq!(image::image_dimensions(&out).unwrap(), (300, 150));
    }

    #[test]
    fn converting_with_a_size_limit_fits_the_image_inside_the_box() {
        let dir = scratch("convert_resize");
        let src = dir.join("wide.png");
        write_png(&src, 800, 400);

        let out =
            convert_image(s(&src), s(&dir), ImageTarget::WebP, Some(200), 90).unwrap();
        assert_eq!(image::image_dimensions(out).unwrap(), (200, 100));
    }

    #[test]
    fn a_smaller_image_is_not_upscaled_to_the_limit() {
        let dir = scratch("convert_small");
        let src = dir.join("tiny.png");
        write_png(&src, 40, 20);

        let out = convert_image(s(&src), s(&dir), ImageTarget::Png, Some(500), 90).unwrap();
        assert_eq!(image::image_dimensions(out).unwrap(), (40, 20));
    }

    #[test]
    fn rotating_swaps_the_dimensions_and_names_the_result() {
        let dir = scratch("rotate");
        let src = dir.join("wide.png");
        write_png(&src, 300, 100);

        let out =
            transform_image(s(&src), ImageTransform::RotateRight, false).unwrap();
        let out = PathBuf::from(out);
        assert!(out.file_name().unwrap().to_string_lossy().contains("rotated right"));
        assert_eq!(image::image_dimensions(&out).unwrap(), (100, 300));
        assert_eq!(
            image::image_dimensions(&src).unwrap(),
            (300, 100),
            "the original must be untouched"
        );
    }

    #[test]
    fn an_in_place_rotate_replaces_the_original_and_leaves_no_temp_file() {
        let dir = scratch("rotate_in_place");
        let src = dir.join("wide.png");
        write_png(&src, 300, 100);

        let out = transform_image(s(&src), ImageTransform::RotateLeft, true).unwrap();
        assert_eq!(PathBuf::from(&out), src);
        assert_eq!(image::image_dimensions(&src).unwrap(), (100, 300));

        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains("notilus-tmp"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[test]
    fn flipping_keeps_the_dimensions() {
        let dir = scratch("flip");
        let src = dir.join("wide.png");
        write_png(&src, 120, 60);

        let out =
            transform_image(s(&src), ImageTransform::FlipHorizontal, false).unwrap();
        assert_eq!(image::image_dimensions(out).unwrap(), (120, 60));
    }

    #[test]
    fn a_non_image_is_a_readable_error_not_a_panic() {
        let dir = scratch("not_an_image");
        write(&dir, "fake.png", b"definitely not a PNG");
        let err = transform_image(
            s(&dir.join("fake.png")),
            ImageTransform::RotateRight,
            false,
        )
        .unwrap_err();
        assert!(err.contains("fake.png"), "got: {err}");
    }

    #[test]
    fn an_unwritable_image_format_is_refused_before_anything_is_decoded() {
        let dir = scratch("gif");
        write(&dir, "anim.gif", b"GIF89a");
        let err =
            transform_image(s(&dir.join("anim.gif")), ImageTransform::Rotate180, true)
                .unwrap_err();
        assert!(err.contains("isn't supported"), "got: {err}");
    }
}

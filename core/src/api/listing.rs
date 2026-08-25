//! Single-directory listing, pre-sorted.
//!
//! Replaces `file_service.dart:listDirectory` plus `FileEntry.from`. The Dart
//! version awaits a separate `stat()` per entry — each one a round trip
//! through Dart's IO thread pool — and then sorts on the UI thread, from a
//! getter that build methods call. Here the metadata comes back with the
//! directory read where the platform allows it, and the sort happens once,
//! off the UI thread, before Dart ever sees the list.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// One filesystem entry. Mirrors Dart's `FileEntry`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirEntryInfo {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Milliseconds since the Unix epoch; negative for pre-1970 timestamps.
    pub modified_ms: i64,
}

impl DirEntryInfo {
    /// Lowercase extension including the leading dot, or `""` for a directory
    /// or an extensionless file.
    pub fn extension(&self) -> String {
        if self.is_dir {
            return String::new();
        }
        match Path::new(&self.name).extension() {
            Some(ext) => format!(".{}", ext.to_string_lossy().to_lowercase()),
            None => String::new(),
        }
    }

    /// The "Kind" column: `Folder`, `PNG file`, or `Document`.
    pub fn kind_label(&self) -> String {
        if self.is_dir {
            return "Folder".to_string();
        }
        let ext = self.extension();
        if ext.is_empty() {
            return "Document".to_string();
        }
        format!("{} file", ext[1..].to_uppercase())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SortField {
    Name,
    Kind,
    Modified,
    Size,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct SortSpec {
    pub field: SortField,
    pub ascending: bool,
    /// Keep directories above files regardless of the active field — the
    /// Finder behaviour the Dart comparator hard-codes.
    pub dirs_first: bool,
    /// Include dot-prefixed entries. Dart's listing always hides them.
    pub include_hidden: bool,
}

impl Default for SortSpec {
    fn default() -> Self {
        Self {
            field: SortField::Name,
            ascending: true,
            dirs_first: true,
            include_hidden: false,
        }
    }
}

/// Lists `path`, sorted per `sort`.
///
/// Unreadable individual entries are skipped rather than failing the listing —
/// a single permission-denied file shouldn't blank the whole folder. An
/// unreadable *directory* is an error, so the UI can show why.
pub fn list_dir(path: String, sort: SortSpec) -> Result<Vec<DirEntryInfo>, String> {
    let read = fs::read_dir(&path).map_err(|e| format!("{path}: {e}"))?;
    let mut out = Vec::new();

    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        // Thumbnails Notilus wrote beside the data are its own bookkeeping,
        // not the user's files. Hidden by name already, but skipped even when
        // hidden files are shown — "show hidden" is for a user's dotfiles, and
        // a `.thumbs` in every folder would bury them.
        if name.eq_ignore_ascii_case(crate::api::thumbnail::SIDECAR_DIR) {
            continue;
        }
        if !sort.include_hidden && name.starts_with('.') {
            continue;
        }
        // symlink_metadata: don't follow links, matching `followLinks: false`
        // on the Dart side. A dangling symlink then lists instead of vanishing.
        let Ok(meta) = entry.metadata().or_else(|_| entry.path().symlink_metadata()) else {
            continue;
        };
        out.push(DirEntryInfo {
            path: entry.path().to_string_lossy().into_owned(),
            name,
            is_dir: meta.is_dir(),
            size: if meta.is_dir() { 0 } else { meta.len() },
            modified_ms: meta.modified().map(to_unix_millis).unwrap_or(0),
        });
    }

    sort_entries(&mut out, sort);
    Ok(out)
}

/// Sorts in place. Split out so the duplicate scanner and any future caller
/// order results identically to the browser.
pub fn sort_entries(entries: &mut [DirEntryInfo], sort: SortSpec) {
    entries.sort_by(|a, b| {
        if sort.dirs_first && a.is_dir != b.is_dir {
            return if a.is_dir {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            };
        }
        let ordering = match sort.field {
            SortField::Name => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
            SortField::Kind => a
                .kind_label()
                .cmp(&b.kind_label())
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())),
            SortField::Modified => a.modified_ms.cmp(&b.modified_ms),
            SortField::Size => a.size.cmp(&b.size),
        };
        if sort.ascending {
            ordering
        } else {
            ordering.reverse()
        }
    });
}

pub(crate) fn to_unix_millis(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        // Pre-epoch mtimes are rare but real (archives, restored backups).
        Err(e) => -(e.duration().as_millis() as i64),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_listing_tests")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(dir: &Path, name: &str, bytes: &[u8]) {
        let mut f = File::create(dir.join(name)).unwrap();
        f.write_all(bytes).unwrap();
    }

    #[test]
    fn lists_and_sorts_directories_before_files() {
        let dir = scratch("basic");
        write(&dir, "b.txt", b"bb");
        write(&dir, "a.txt", b"a");
        fs::create_dir(dir.join("zzz_folder")).unwrap();

        let out = list_dir(dir.to_string_lossy().into_owned(), SortSpec::default()).unwrap();
        let names: Vec<_> = out.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["zzz_folder", "a.txt", "b.txt"]);
        assert!(out[0].is_dir);
        assert_eq!(out[1].size, 1);
        assert_eq!(out[2].size, 2);
    }

    #[test]
    fn the_thumbnail_sidecar_is_never_listed() {
        // `.thumbs` holds thumbnails Notilus wrote beside the data. It is its
        // own bookkeeping, not the user's files, so it stays out of the listing
        // even when hidden files are being shown.
        let dir = scratch("sidecar");
        std::fs::create_dir_all(dir.join(crate::api::thumbnail::SIDECAR_DIR))
            .unwrap();
        write(&dir, "photo.jpg", b"x");

        for include_hidden in [false, true] {
            let out = list_dir(
                dir.to_string_lossy().into_owned(),
                SortSpec {
                    include_hidden,
                    ..Default::default()
                },
            )
            .unwrap();
            let names: Vec<_> = out.iter().map(|e| e.name.as_str()).collect();
            assert_eq!(names, vec!["photo.jpg"], "include_hidden={include_hidden}");
        }
    }

    #[test]
    fn hidden_entries_are_excluded_unless_requested() {
        let dir = scratch("hidden");
        write(&dir, "visible.txt", b"x");
        write(&dir, ".hidden", b"x");

        let shown = list_dir(dir.to_string_lossy().into_owned(), SortSpec::default()).unwrap();
        assert_eq!(shown.len(), 1);

        let all = list_dir(
            dir.to_string_lossy().into_owned(),
            SortSpec {
                include_hidden: true,
                ..SortSpec::default()
            },
        )
        .unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn descending_size_sort_still_keeps_folders_first() {
        let dir = scratch("bysize");
        write(&dir, "small.bin", b"1");
        write(&dir, "large.bin", b"1234567890");
        fs::create_dir(dir.join("folder")).unwrap();

        let out = list_dir(
            dir.to_string_lossy().into_owned(),
            SortSpec {
                field: SortField::Size,
                ascending: false,
                ..SortSpec::default()
            },
        )
        .unwrap();
        let names: Vec<_> = out.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["folder", "large.bin", "small.bin"]);
    }

    #[test]
    fn kind_and_extension_match_the_dart_labels() {
        let file = DirEntryInfo {
            path: "/x/Photo.PNG".into(),
            name: "Photo.PNG".into(),
            is_dir: false,
            size: 1,
            modified_ms: 0,
        };
        assert_eq!(file.extension(), ".png");
        assert_eq!(file.kind_label(), "PNG file");

        let bare = DirEntryInfo {
            name: "LICENSE".into(),
            ..file.clone()
        };
        assert_eq!(bare.extension(), "");
        assert_eq!(bare.kind_label(), "Document");

        let dir = DirEntryInfo {
            is_dir: true,
            ..file
        };
        assert_eq!(dir.kind_label(), "Folder");
    }

    #[test]
    fn a_missing_directory_is_an_error_naming_the_path() {
        let err = list_dir("/definitely/not/here".into(), SortSpec::default()).unwrap_err();
        assert!(err.contains("/definitely/not/here"), "got: {err}");
    }
}

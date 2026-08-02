//! Move files to the platform recycle bin.
//!
//! Closes a data-loss bug, not just a feature gap. `file_actions_service.dart`
//! used a Finder AppleScript on macOS — fine — but **hard-deleted on Windows
//! and Linux** (`Directory.delete(recursive: true)` / `File.delete()`), with no
//! undo anywhere in the app. A misclick was unrecoverable on two of the three
//! desktop platforms.
//!
//! The `trash` crate implements the real thing per platform: `IFileOperation`
//! on Windows, `NSFileManager`'s trashItem on macOS, and the XDG Trash spec
//! (`~/.local/share/Trash` with `.trashinfo` records) on Linux — which means
//! items land where the desktop's own Trash UI can restore them.

use crate::api::fileops::FailedItem;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TrashOutcome {
    /// Paths successfully moved to the recycle bin.
    pub trashed: Vec<String>,
    pub failed: Vec<FailedItem>,
}

impl TrashOutcome {
    pub fn is_success(&self) -> bool {
        self.failed.is_empty()
    }
}

/// Moves everything in `paths` to the recycle bin.
///
/// Batched in one call so the platform plays its animation/sound once for the
/// whole selection rather than per file — the behaviour the Dart `trashAll`
/// went out of its way to get on macOS, now available everywhere.
///
/// A batch failure is retried per path so the outcome names exactly which
/// items survived, instead of failing the whole selection over one locked file.
pub fn move_to_trash(paths: Vec<String>) -> TrashOutcome {
    let mut outcome = TrashOutcome::default();
    if paths.is_empty() {
        return outcome;
    }

    // Paths that are already gone count as trashed — a stale selection
    // shouldn't surface as an error the user has to dismiss.
    let present: Vec<String> = paths
        .into_iter()
        .filter(|p| std::fs::symlink_metadata(p).is_ok())
        .collect();
    if present.is_empty() {
        return outcome;
    }

    match trash::delete_all(&present) {
        Ok(()) => outcome.trashed = present,
        Err(_) => {
            for path in present {
                match trash::delete(&path) {
                    Ok(()) => outcome.trashed.push(path),
                    Err(e) => outcome.failed.push(FailedItem {
                        path,
                        error: e.to_string(),
                    }),
                }
            }
        }
    }
    outcome
}

/// Permanently deletes, bypassing the recycle bin.
///
/// Kept separate and explicitly named so it can never be reached by accident:
/// the UI must ask before calling this. Used for "Delete Immediately"
/// (Shift+Delete) and for emptying a scan result the user has confirmed.
pub fn delete_permanently(paths: Vec<String>) -> TrashOutcome {
    let mut outcome = TrashOutcome::default();
    for path in paths {
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(_) => continue, // already gone
        };
        let result = if meta.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        match result {
            Ok(()) => outcome.trashed.push(path),
            Err(e) => outcome.failed.push(FailedItem {
                path,
                error: e.to_string(),
            }),
        }
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_trash_tests")
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

    #[test]
    fn permanent_delete_removes_files_and_trees() {
        let dir = scratch("permanent");
        let file = dir.join("a.txt");
        let tree = dir.join("tree");
        write(&file, b"x");
        write(&tree.join("nested/b.txt"), b"y");

        let out = delete_permanently(vec![
            file.to_string_lossy().into_owned(),
            tree.to_string_lossy().into_owned(),
        ]);
        assert!(out.is_success(), "{out:?}");
        assert_eq!(out.trashed.len(), 2);
        assert!(!file.exists());
        assert!(!tree.exists());
    }

    #[test]
    fn already_missing_paths_are_not_reported_as_failures() {
        let dir = scratch("missing");
        let out = delete_permanently(vec![dir
            .join("never_existed")
            .to_string_lossy()
            .into_owned()]);
        assert!(out.is_success());
        assert!(out.trashed.is_empty());

        let out = move_to_trash(vec![dir
            .join("also_gone")
            .to_string_lossy()
            .into_owned()]);
        assert!(out.is_success());
        assert!(out.trashed.is_empty());
    }

    #[test]
    fn an_empty_batch_is_a_no_op() {
        assert!(move_to_trash(vec![]).is_success());
        assert!(delete_permanently(vec![]).is_success());
    }

    // The real recycle bin is a shared, user-visible system resource. Putting
    // files into it from a test would leave debris in whoever's Trash ran the
    // suite, so only the platform-independent contract is asserted here; the
    // trashing itself is covered by the `trash` crate's own suite.
    #[test]
    fn trashing_a_real_file_moves_it_out_of_the_folder() {
        if std::env::var_os("NOTILUS_TEST_REAL_TRASH").is_none() {
            eprintln!("skipping: set NOTILUS_TEST_REAL_TRASH=1 to exercise the system Trash");
            return;
        }
        let dir = scratch("real");
        let file = dir.join("notilus_trash_probe.txt");
        write(&file, b"probe");

        let out = move_to_trash(vec![file.to_string_lossy().into_owned()]);
        assert!(out.is_success(), "{out:?}");
        assert!(!file.exists());
    }
}

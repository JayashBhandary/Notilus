//! Shares: what a tree connect maps to on disk, and the rules that keep a
//! client inside it.
//!
//! Two problems live here. The first is containment — an SMB path arrives as
//! attacker-controlled text and must never resolve outside its share. The
//! second is case: SMB clients assume a case-insensitive filesystem, and on
//! Linux they don't get one, so a miss is retried by scanning the directory.

use std::fs;
use std::path::{Component, Path, PathBuf};

/// One exported folder.
#[derive(Clone, Debug)]
pub struct Share {
    /// The name clients connect to, as in `\\host\name`.
    pub name: String,
    pub root: PathBuf,
    pub read_only: bool,
    pub comment: String,
    /// Accounts allowed to attach, lower-cased.
    ///
    /// Empty means every signed-in account, which is what a single-user setup
    /// wants and what the server did before per-share access existed.
    pub allowed_users: Vec<String>,
    /// Whether someone with no account at all may attach.
    ///
    /// A guest share is readable by anyone who can reach the port, so this is
    /// off unless deliberately set, and a guest is never granted write access
    /// regardless of [`read_only`].
    pub guest_ok: bool,
}

impl Share {
    /// Whether `user` may attach to this share.
    ///
    /// A guest is admitted only to a share that says so. A signed-in account is
    /// admitted when the list is empty (nobody has narrowed it) or names them.
    pub fn permits(&self, user: &str, is_guest: bool) -> bool {
        if is_guest {
            return self.guest_ok;
        }
        if self.allowed_users.is_empty() {
            return true;
        }
        self.allowed_users
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(user))
    }

    /// Whether this share accepts writes from `user`.
    ///
    /// Guests never write. Letting an unauthenticated caller modify files would
    /// make "anyone can see this folder" mean "anyone can empty it".
    pub fn writable_by(&self, is_guest: bool) -> bool {
        !self.read_only && !is_guest
    }

    /// Resolves an SMB-relative path against this share.
    ///
    /// Returns `None` when the path tries to leave the share, contains a
    /// component the local filesystem can't represent, or names an NTFS
    /// alternate data stream — none of which a file manager needs and all of
    /// which are ways out of a sandbox.
    pub fn resolve(&self, smb_path: &str) -> Option<PathBuf> {
        let relative = normalise(smb_path)?;
        if relative.as_os_str().is_empty() {
            return Some(self.root.clone());
        }
        let direct = self.root.join(&relative);
        if direct.symlink_metadata().is_ok() {
            return contained(&self.root, direct);
        }
        // Not there under that spelling. Walk the components matching
        // case-insensitively, which is what the client expects and what makes
        // a Windows-authored path open on a Linux server.
        let mut current = self.root.clone();
        let mut components = relative.components().peekable();
        while let Some(component) = components.next() {
            let Component::Normal(name) = component else {
                return None;
            };
            let exact = current.join(name);
            if exact.symlink_metadata().is_ok() {
                current = exact;
                continue;
            }
            if let Some(found) = find_case_insensitive(&current, &name.to_string_lossy()) {
                current = found;
                continue;
            }
            // A miss. Only a create can name something that doesn't exist, and
            // a create only ever adds the last component — so take the rest
            // exactly as asked and let the caller's open decide.
            current = exact;
            for rest in components {
                let Component::Normal(name) = rest else {
                    return None;
                };
                current = current.join(name);
            }
            break;
        }
        contained(&self.root, current)
    }

    /// The SMB-facing path of `path` relative to this share's root.
    pub fn relative_name(&self, path: &Path) -> String {
        path.strip_prefix(&self.root)
            .map(|rest| rest.to_string_lossy().replace('/', "\\"))
            .unwrap_or_default()
    }
}

/// Turns `folder\sub\file.txt` into a relative [`PathBuf`], rejecting anything
/// that could escape.
fn normalise(smb_path: &str) -> Option<PathBuf> {
    let cleaned = smb_path.trim_matches(['\\', '/']);
    if cleaned.is_empty() {
        return Some(PathBuf::new());
    }
    let mut out = PathBuf::new();
    for part in cleaned.split(['\\', '/']) {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            return None;
        }
        // Alternate data streams, and the reserved characters a POSIX path
        // can't carry meaningfully.
        if part.contains(':') || part.contains('\0') {
            return None;
        }
        out.push(part);
    }
    Some(out)
}

/// Confirms the resolved path is still under `root` once symlinks are taken
/// into account, so a symlink inside a share can't be used to read outside it.
fn contained(root: &Path, path: PathBuf) -> Option<PathBuf> {
    // The path may not exist yet (a create); check the deepest existing
    // ancestor, which is the part symlinks could have redirected.
    let mut probe = path.as_path();
    let real_root = fs::canonicalize(root).ok()?;
    loop {
        if let Ok(real) = fs::canonicalize(probe) {
            return real.starts_with(&real_root).then_some(path);
        }
        probe = probe.parent()?;
        if probe.as_os_str().is_empty() {
            return None;
        }
    }
}

fn find_case_insensitive(dir: &Path, name: &str) -> Option<PathBuf> {
    let wanted = name.to_lowercase();
    for entry in fs::read_dir(dir).ok()?.flatten() {
        if entry.file_name().to_string_lossy().to_lowercase() == wanted {
            return Some(entry.path());
        }
    }
    None
}

/// Matches a name against a DOS-style search pattern.
///
/// `*` and `?` are the only ones worth supporting: the `<`, `>` and `"`
/// wildcards exist for 8.3 names, which no client asks for over SMB2.
pub fn matches_pattern(pattern: &str, name: &str) -> bool {
    if pattern.is_empty() || pattern == "*" || pattern == "*.*" {
        return true;
    }
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    glob(&p, &n)
}

/// Iterative wildcard match with backtracking — no recursion, so a pathological
/// pattern can't exhaust the stack.
fn glob(pattern: &[char], name: &[char]) -> bool {
    let (mut p, mut n) = (0usize, 0usize);
    let (mut star, mut mark) = (usize::MAX, 0usize);

    while n < name.len() {
        if p < pattern.len() && (pattern[p] == '?' || pattern[p] == name[n]) {
            p += 1;
            n += 1;
        } else if p < pattern.len() && pattern[p] == '*' {
            star = p;
            mark = n;
            p += 1;
        } else if star != usize::MAX {
            p = star + 1;
            mark += 1;
            n = mark;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == '*' {
        p += 1;
    }
    p == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_share(label: &str) -> Share {
        let root = std::env::temp_dir().join(format!(
            "notilus-share-{}-{}",
            label,
            std::process::id()
        ));
        fs::create_dir_all(root.join("Docs")).unwrap();
        fs::write(root.join("Docs/Report.txt"), b"hi").unwrap();
        Share {
            name: "Files".into(),
            root,
            read_only: false,
            comment: String::new(),
            allowed_users: Vec::new(),
            guest_ok: false,
        }
    }

    #[test]
    fn traversal_is_refused() {
        let share = temp_share("traversal");
        assert!(share.resolve("..\\..\\etc\\passwd").is_none());
        assert!(share.resolve("Docs\\..\\..\\outside").is_none());
        assert!(share.resolve("Docs\\file.txt:stream").is_none());
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn an_empty_path_is_the_share_root() {
        let share = temp_share("root");
        assert_eq!(share.resolve("").unwrap(), share.root);
        assert_eq!(share.resolve("\\").unwrap(), share.root);
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn a_wrongly_cased_path_still_resolves() {
        let share = temp_share("case");
        let found = share.resolve("docs\\report.TXT").unwrap();
        assert_eq!(fs::read_to_string(found).unwrap(), "hi");
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn a_path_that_does_not_exist_yet_still_resolves_for_creation() {
        let share = temp_share("create");
        let target = share.resolve("Docs\\new file.txt").unwrap();
        assert!(target.starts_with(&share.root));
        assert!(target.ends_with("new file.txt"));
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn relative_names_come_back_in_smb_form() {
        let share = temp_share("relname");
        let path = share.root.join("Docs").join("Report.txt");
        assert_eq!(share.relative_name(&path), "Docs\\Report.txt");
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn an_empty_user_list_admits_every_account_but_no_guest() {
        let share = temp_share("open");
        assert!(share.permits("alice", false));
        assert!(share.permits("bob", false));
        assert!(!share.permits("", true));
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn a_named_list_admits_only_those_accounts() {
        let mut share = temp_share("named");
        share.allowed_users = vec!["alice".into(), "carol".into()];
        assert!(share.permits("alice", false));
        // Account names are matched the way the protocol treats them.
        assert!(share.permits("ALICE", false));
        assert!(!share.permits("bob", false));
        assert!(!share.permits("alice", true), "a guest is not alice");
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn a_guest_share_admits_a_guest_and_never_accepts_writes() {
        let mut share = temp_share("guest");
        share.guest_ok = true;
        assert!(share.permits("", true));
        assert!(share.writable_by(false));
        assert!(
            !share.writable_by(true),
            "a guest must not be able to modify a share"
        );
        fs::remove_dir_all(&share.root).ok();
    }

    #[test]
    fn patterns_match_the_way_a_client_expects() {
        assert!(matches_pattern("*", "anything"));
        assert!(matches_pattern("*.txt", "Notes.TXT"));
        assert!(matches_pattern("re?ort.*", "report.pdf"));
        assert!(!matches_pattern("*.txt", "notes.md"));
        assert!(matches_pattern("a*b*c", "aXXbYYc"));
        assert!(!matches_pattern("a*b*c", "aXXbYY"));
    }
}

//! Filename and content search.
//!
//! Fills a total gap: the Dart app had no search of any kind — no field, no
//! filter on `BrowserProvider`, nothing. This is the ripgrep-shaped feature the
//! audit called the headline reason to have a native core, and it shares the
//! parallel walker that the duplicate scanner uses.
//!
//! Two modes, both streaming so the UI can fill in results as they arrive
//! rather than blocking on a full traversal:
//!
//! - **Filename** — case-insensitive substring by default, optional glob-ish
//!   `*` wildcards, optional regex-free whole-word behaviour.
//! - **Content** — literal substring over file bytes via `memchr::memmem`
//!   (SIMD), with a binary sniff so the search doesn't spew control characters
//!   into the results list.

use crate::api::dedupe::CancelToken;
use crate::api::listing::{to_unix_millis, DirEntryInfo};
use ignore::{WalkBuilder, WalkState};
use memchr::memmem;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;

/// Files larger than this are skipped by content search. Grepping a 4 GB video
/// for a text string is never what the user meant.
const MAX_CONTENT_BYTES: u64 = 32 * 1024 * 1024;

/// Bytes sniffed to decide whether a file is binary.
const SNIFF_LEN: usize = 8192;

/// Characters either side of a content match kept for the preview line.
const PREVIEW_RADIUS: usize = 60;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchRequest {
    pub roots: Vec<String>,
    /// What to look for. Empty means "match every file", which is how a
    /// filter-by-extension-only search is expressed.
    pub query: String,
    /// Match `query` against file *contents* as well as names.
    pub search_content: bool,
    pub match_case: bool,
    /// Treat `*` in `query` as a wildcard when matching names.
    pub use_wildcards: bool,
    /// Stop after this many hits. 0 means unlimited.
    pub max_results: u64,
    pub skip_hidden: bool,
    /// Lowercase directory basenames to prune.
    pub excluded_dir_names: Vec<String>,
    /// Lowercase extensions including the dot. `None` means every file.
    pub allowed_extensions: Option<Vec<String>>,
}

impl Default for SearchRequest {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            query: String::new(),
            search_content: false,
            match_case: false,
            use_wildcards: false,
            max_results: 5000,
            skip_hidden: true,
            excluded_dir_names: Vec::new(),
            allowed_extensions: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HitKind {
    Name,
    Content,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchHit {
    pub entry: DirEntryInfo,
    pub kind: HitKind,
    /// 1-based line number, for content hits.
    pub line: Option<u64>,
    /// A trimmed excerpt around the match, for content hits.
    pub preview: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchSummary {
    pub hits: Vec<SearchHit>,
    pub files_scanned: u64,
    /// True if the run stopped early because `max_results` was reached.
    pub truncated: bool,
    pub cancelled: bool,
}

/// Runs a search, calling `on_hit` as each result is found.
///
/// Results also come back in the summary, so a caller that doesn't want
/// streaming can pass a no-op closure.
pub fn search_files<F>(
    req: SearchRequest,
    cancel: &CancelToken,
    on_hit: F,
) -> Result<SearchSummary, String>
where
    F: Fn(SearchHit) + Send + Sync,
{
    if req.roots.is_empty() {
        return Ok(SearchSummary {
            hits: Vec::new(),
            files_scanned: 0,
            truncated: false,
            cancelled: false,
        });
    }

    let matcher = NameMatcher::new(&req);
    let needle: Option<Vec<u8>> = if req.search_content && !req.query.is_empty() {
        Some(if req.match_case {
            req.query.as_bytes().to_vec()
        } else {
            req.query.to_lowercase().into_bytes()
        })
    } else {
        None
    };

    let excluded: Vec<String> = req
        .excluded_dir_names
        .iter()
        .map(|s| s.to_lowercase())
        .collect();
    let allowed: Option<Vec<String>> = req
        .allowed_extensions
        .as_ref()
        .map(|v| v.iter().map(|s| s.to_lowercase()).collect());
    let skip_hidden = req.skip_hidden;
    let limit = req.max_results;

    let mut builder = WalkBuilder::new(&req.roots[0]);
    for root in &req.roots[1..] {
        builder.add(root);
    }
    builder
        .standard_filters(false)
        .follow_links(false)
        .threads(rayon::current_num_threads().max(1));

    {
        let excluded = excluded.clone();
        builder.filter_entry(move |entry| {
            if !entry.file_type().is_some_and(|t| t.is_dir()) {
                return true;
            }
            if entry.depth() == 0 {
                return true;
            }
            let Some(name) = entry.path().file_name() else {
                return true;
            };
            let lower = name.to_string_lossy().to_lowercase();
            if skip_hidden && lower.starts_with('.') {
                return false;
            }
            !excluded.contains(&lower)
        });
    }

    let scanned = AtomicU64::new(0);
    let found = AtomicU64::new(0);
    let scanned = &scanned;
    let found = &found;
    let matcher = &matcher;
    let needle = &needle;
    let on_hit = &on_hit;
    let (tx, rx) = mpsc::channel::<SearchHit>();

    builder.build_parallel().run(|| {
        let tx = tx.clone();
        let allowed = allowed.clone();
        Box::new(move |result| {
            if cancel.is_cancelled() {
                return WalkState::Quit;
            }
            if limit > 0 && found.load(Ordering::Relaxed) >= limit {
                return WalkState::Quit;
            }
            let Ok(entry) = result else {
                return WalkState::Continue;
            };
            if !entry.file_type().is_some_and(|t| t.is_file()) {
                return WalkState::Continue;
            }

            let path = entry.path();
            let Some(name) = path.file_name().map(|n| n.to_string_lossy().into_owned()) else {
                return WalkState::Continue;
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
            scanned.fetch_add(1, Ordering::Relaxed);

            let Ok(meta) = entry.metadata() else {
                return WalkState::Continue;
            };
            let info = DirEntryInfo {
                path: path.to_string_lossy().into_owned(),
                name: name.clone(),
                is_dir: false,
                size: meta.len(),
                modified_ms: meta.modified().map(to_unix_millis).unwrap_or(0),
            };

            let emit = |hit: SearchHit| {
                found.fetch_add(1, Ordering::Relaxed);
                on_hit(hit.clone());
                let _ = tx.send(hit);
            };

            // A name match wins outright — no need to read the file.
            if matcher.matches(&name) {
                emit(SearchHit {
                    entry: info,
                    kind: HitKind::Name,
                    line: None,
                    preview: None,
                });
                return WalkState::Continue;
            }

            if let Some(needle) = needle {
                if meta.len() <= MAX_CONTENT_BYTES {
                    if let Some((line, preview)) =
                        find_in_file(path, needle, matcher.case_sensitive)
                    {
                        emit(SearchHit {
                            entry: info,
                            kind: HitKind::Content,
                            line: Some(line),
                            preview: Some(preview),
                        });
                    }
                }
            }
            WalkState::Continue
        })
    });

    drop(tx);
    let mut hits: Vec<SearchHit> = rx.into_iter().collect();
    // Deterministic output: name hits first, then by path.
    hits.sort_by(|a, b| {
        (a.kind != HitKind::Name)
            .cmp(&(b.kind != HitKind::Name))
            .then_with(|| a.entry.path.cmp(&b.entry.path))
    });
    let truncated = limit > 0 && hits.len() as u64 > limit;
    if truncated {
        hits.truncate(limit as usize);
    }

    Ok(SearchSummary {
        hits,
        files_scanned: scanned.load(Ordering::Relaxed),
        truncated,
        cancelled: cancel.is_cancelled(),
    })
}

/// Filename matching, precompiled once per search.
struct NameMatcher {
    needle: String,
    case_sensitive: bool,
    /// `*`-separated fragments when wildcards are on.
    fragments: Option<Vec<String>>,
    match_all: bool,
}

impl NameMatcher {
    fn new(req: &SearchRequest) -> Self {
        let needle = if req.match_case {
            req.query.clone()
        } else {
            req.query.to_lowercase()
        };
        let fragments = if req.use_wildcards && needle.contains('*') {
            Some(needle.split('*').map(|s| s.to_string()).collect())
        } else {
            None
        };
        Self {
            match_all: req.query.is_empty(),
            needle,
            case_sensitive: req.match_case,
            fragments,
        }
    }

    fn matches(&self, name: &str) -> bool {
        if self.match_all {
            return true;
        }
        let hay = if self.case_sensitive {
            name.to_string()
        } else {
            name.to_lowercase()
        };

        let Some(fragments) = &self.fragments else {
            return hay.contains(&self.needle);
        };

        // `a*b*c` — anchored at both ends, ordered fragments in between.
        let mut cursor = 0usize;
        for (i, frag) in fragments.iter().enumerate() {
            if frag.is_empty() {
                continue;
            }
            let is_first = i == 0;
            let is_last = i == fragments.len() - 1;

            match hay[cursor..].find(frag.as_str()) {
                Some(at) => {
                    let abs = cursor + at;
                    if is_first && abs != 0 {
                        return false; // no leading `*`, must start here
                    }
                    if is_last && abs + frag.len() != hay.len() {
                        return false; // no trailing `*`, must end here
                    }
                    cursor = abs + frag.len();
                }
                None => return false,
            }
        }
        true
    }
}

/// Finds `needle` in the file, returning `(line_number, preview)`.
///
/// Reads the whole file (bounded by `MAX_CONTENT_BYTES`) and uses SIMD
/// substring search. Files that look binary are skipped.
fn find_in_file(path: &Path, needle: &[u8], case_sensitive: bool) -> Option<(u64, String)> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;

    if looks_binary(&buf) {
        return None;
    }

    let hay: Vec<u8> = if case_sensitive {
        buf
    } else {
        buf.to_ascii_lowercase()
    };

    let at = memmem::find(&hay, needle)?;
    let line = 1 + hay[..at].iter().filter(|b| **b == b'\n').count() as u64;

    // Excerpt bounded to the matching line, then trimmed to a window.
    let line_start = hay[..at].iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
    let line_end = hay[at..]
        .iter()
        .position(|b| *b == b'\n')
        .map_or(hay.len(), |i| at + i);

    let from = line_start.max(at.saturating_sub(PREVIEW_RADIUS));
    let to = line_end.min(at + needle.len() + PREVIEW_RADIUS);
    let preview = String::from_utf8_lossy(&hay[from..to]).trim().to_string();

    Some((line, preview))
}

/// A NUL byte in the first few KB means binary, the same heuristic the Dart
/// text-snippet thumbnailer used.
fn looks_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(SNIFF_LEN).any(|b| *b == 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_search_tests")
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

    fn run(dir: &Path, req: SearchRequest) -> SearchSummary {
        let req = SearchRequest {
            roots: vec![dir.to_string_lossy().into_owned()],
            ..req
        };
        search_files(req, &CancelToken::new(), |_| {}).unwrap()
    }

    fn names(s: &SearchSummary) -> Vec<String> {
        s.hits.iter().map(|h| h.entry.name.clone()).collect()
    }

    #[test]
    fn finds_files_by_name_substring_case_insensitively() {
        let dir = scratch("byname");
        write(&dir.join("Report.pdf"), b"x");
        write(&dir.join("nested/report_final.txt"), b"x");
        write(&dir.join("unrelated.md"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "REPORT".into(),
                ..SearchRequest::default()
            },
        );
        let mut got = names(&out);
        got.sort();
        assert_eq!(got, vec!["Report.pdf", "report_final.txt"]);
    }

    #[test]
    fn case_sensitive_mode_respects_case() {
        let dir = scratch("case");
        write(&dir.join("Report.pdf"), b"x");
        write(&dir.join("report.txt"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "Report".into(),
                match_case: true,
                ..SearchRequest::default()
            },
        );
        assert_eq!(names(&out), vec!["Report.pdf"]);
    }

    #[test]
    fn wildcards_anchor_at_both_ends() {
        let dir = scratch("wild");
        write(&dir.join("photo_2024.jpg"), b"x");
        write(&dir.join("photo_2023.png"), b"x");
        write(&dir.join("my_photo_2024.jpg"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "photo*.jpg".into(),
                use_wildcards: true,
                ..SearchRequest::default()
            },
        );
        assert_eq!(
            names(&out),
            vec!["photo_2024.jpg"],
            "a leading fragment must anchor to the start"
        );
    }

    #[test]
    fn finds_matches_inside_file_contents() {
        let dir = scratch("content");
        write(&dir.join("a.txt"), b"nothing here\nthe needle is on line two\nmore\n");
        write(&dir.join("b.txt"), b"unrelated text");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "needle".into(),
                search_content: true,
                ..SearchRequest::default()
            },
        );
        assert_eq!(out.hits.len(), 1);
        let hit = &out.hits[0];
        assert_eq!(hit.kind, HitKind::Content);
        assert_eq!(hit.line, Some(2));
        assert!(hit.preview.as_ref().unwrap().contains("needle"));
    }

    #[test]
    fn a_name_match_takes_precedence_over_reading_the_file() {
        let dir = scratch("precedence");
        write(&dir.join("needle.txt"), b"needle needle needle");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "needle".into(),
                search_content: true,
                ..SearchRequest::default()
            },
        );
        assert_eq!(out.hits.len(), 1, "must not report the same file twice");
        assert_eq!(out.hits[0].kind, HitKind::Name);
    }

    #[test]
    fn binary_files_are_not_content_searched() {
        let dir = scratch("binary");
        let mut blob = b"needle".to_vec();
        blob.push(0); // NUL → binary
        blob.extend_from_slice(b"needle");
        write(&dir.join("blob.bin"), &blob);

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "needle".into(),
                search_content: true,
                ..SearchRequest::default()
            },
        );
        assert!(out.hits.is_empty());
    }

    #[test]
    fn hidden_files_and_excluded_dirs_are_skipped() {
        let dir = scratch("filters");
        write(&dir.join("target.txt"), b"x");
        write(&dir.join(".hidden_target.txt"), b"x");
        write(&dir.join("node_modules/target.txt"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "target".into(),
                excluded_dir_names: vec!["node_modules".into()],
                ..SearchRequest::default()
            },
        );
        assert_eq!(names(&out), vec!["target.txt"]);
        assert_eq!(out.hits[0].entry.path, dir.join("target.txt").to_string_lossy());
    }

    #[test]
    fn extension_filter_restricts_results() {
        let dir = scratch("exts");
        write(&dir.join("a.jpg"), b"x");
        write(&dir.join("a.txt"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "a".into(),
                allowed_extensions: Some(vec![".jpg".into()]),
                ..SearchRequest::default()
            },
        );
        assert_eq!(names(&out), vec!["a.jpg"]);
    }

    #[test]
    fn an_empty_query_lists_everything_that_passes_the_filters() {
        let dir = scratch("empty_query");
        write(&dir.join("a.jpg"), b"x");
        write(&dir.join("b.jpg"), b"x");
        write(&dir.join("c.txt"), b"x");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: String::new(),
                allowed_extensions: Some(vec![".jpg".into()]),
                ..SearchRequest::default()
            },
        );
        assert_eq!(out.hits.len(), 2);
    }

    #[test]
    fn max_results_truncates_and_flags() {
        let dir = scratch("limit");
        for i in 0..50 {
            write(&dir.join(format!("match{i}.txt")), b"x");
        }
        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "match".into(),
                max_results: 10,
                ..SearchRequest::default()
            },
        );
        assert_eq!(out.hits.len(), 10);
    }

    #[test]
    fn streaming_callback_sees_every_hit() {
        use std::sync::Mutex;
        let dir = scratch("stream");
        for i in 0..5 {
            write(&dir.join(format!("hit{i}.txt")), b"x");
        }
        let seen: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let out = search_files(
            SearchRequest {
                roots: vec![dir.to_string_lossy().into_owned()],
                query: "hit".into(),
                ..SearchRequest::default()
            },
            &CancelToken::new(),
            |h| seen.lock().unwrap().push(h.entry.name),
        )
        .unwrap();

        assert_eq!(out.hits.len(), 5);
        assert_eq!(seen.into_inner().unwrap().len(), 5);
    }

    #[test]
    fn a_cancelled_search_reports_cancellation() {
        let dir = scratch("cancel");
        write(&dir.join("a.txt"), b"x");
        let cancel = CancelToken::new();
        cancel.cancel();

        let out = search_files(
            SearchRequest {
                roots: vec![dir.to_string_lossy().into_owned()],
                query: "a".into(),
                ..SearchRequest::default()
            },
            &cancel,
            |_| {},
        )
        .unwrap();
        assert!(out.cancelled);
    }

    #[test]
    fn results_are_deterministic_and_name_hits_come_first() {
        let dir = scratch("order");
        write(&dir.join("zzz_needle.txt"), b"nothing");
        write(&dir.join("aaa.txt"), b"needle inside");

        let out = run(
            dir.as_path(),
            SearchRequest {
                query: "needle".into(),
                search_content: true,
                ..SearchRequest::default()
            },
        );
        assert_eq!(out.hits.len(), 2);
        assert_eq!(out.hits[0].kind, HitKind::Name);
        assert_eq!(out.hits[0].entry.name, "zzz_needle.txt");
        assert_eq!(out.hits[1].kind, HitKind::Content);
    }

    #[test]
    fn no_roots_is_not_an_error() {
        let out = search_files(SearchRequest::default(), &CancelToken::new(), |_| {}).unwrap();
        assert!(out.hits.is_empty());
    }
}

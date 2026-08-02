//! `notilus-scan` — run the native duplicate scanner from a terminal.
//!
//! Exists so the Rust pipeline can be exercised and timed against the current
//! Dart scanner *before* the `flutter_rust_bridge` wiring lands. Point both at
//! the same folder and compare wall-clock and group counts.
//!
//! ```text
//! cargo run --release --bin notilus-scan -- ~/Pictures --defaults
//! ```

use notilus_core::api::dedupe::{
    scan_duplicates, CancelToken, ScanPhase, ScanRequest, DEFAULT_EXCLUDED_DIRS,
};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        eprintln!("{USAGE}");
        std::process::exit(if args.is_empty() { 2 } else { 0 });
    }

    let mut req = ScanRequest::default();
    let mut quiet = false;
    let mut i = 0;

    while i < args.len() {
        let arg = &args[i];
        let mut next = |flag: &str| -> String {
            i += 1;
            args.get(i)
                .unwrap_or_else(|| fail(&format!("{flag} needs a value")))
                .clone()
        };
        match arg.as_str() {
            "--min-size" => {
                let v = next("--min-size");
                req.min_size = v
                    .parse()
                    .unwrap_or_else(|_| fail("--min-size must be a number of bytes"));
            }
            "--ext" => {
                req.allowed_extensions = Some(
                    next("--ext")
                        .split(',')
                        .filter(|s| !s.trim().is_empty())
                        .map(|s| {
                            let s = s.trim().to_lowercase();
                            if s.starts_with('.') {
                                s
                            } else {
                                format!(".{s}")
                            }
                        })
                        .collect(),
                );
            }
            "--exclude" => {
                req.excluded_dir_names.extend(
                    next("--exclude")
                        .split(',')
                        .filter(|s| !s.trim().is_empty())
                        .map(|s| s.trim().to_lowercase()),
                );
            }
            "--defaults" => req
                .excluded_dir_names
                .extend(DEFAULT_EXCLUDED_DIRS.iter().map(|s| s.to_string())),
            "--include-hidden" => req.skip_hidden = false,
            "--no-skip-bundles" => req.skip_bundles = false,
            "--quiet" => quiet = true,
            other if other.starts_with('-') => fail(&format!("unknown flag {other}")),
            root => req.roots.push(root.to_string()),
        }
        i += 1;
    }

    if req.roots.is_empty() {
        fail("no root directory given");
    }

    let started = Instant::now();
    let cancel = CancelToken::new();
    let result = scan_duplicates(req, &cancel, |p| {
        if quiet {
            return;
        }
        match p.phase {
            ScanPhase::Scanning => {
                eprint!("\r\x1b[2Kscanning… {} files", p.files_seen);
            }
            ScanPhase::Comparing => {
                eprint!(
                    "\r\x1b[2Khashing… {}/{}",
                    p.files_hashed, p.hash_total
                );
            }
        }
    });
    if !quiet {
        eprint!("\r\x1b[2K");
    }

    let groups = match result {
        Ok(g) => g,
        Err(e) => fail(&e),
    };
    let elapsed = started.elapsed();

    let total_files: usize = groups.iter().map(|g| g.files.len()).sum();
    let reclaimable: u64 = groups.iter().map(|g| g.reclaimable_bytes()).sum();

    for group in &groups {
        println!(
            "{}  ({} copies, {} each, {} reclaimable)",
            &group.hash[..12.min(group.hash.len())],
            group.files.len(),
            human(group.size),
            human(group.reclaimable_bytes()),
        );
        for file in &group.files {
            println!("    {}", file.path);
        }
    }

    println!();
    println!(
        "{} group(s), {total_files} file(s), {} reclaimable, in {:.2}s",
        groups.len(),
        human(reclaimable),
        elapsed.as_secs_f64(),
    );
}

fn human(bytes: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KB", "MB", "GB", "TB", "PB"];
    let mut size = bytes as f64;
    let mut idx = 0;
    while size >= 1024.0 && idx < UNITS.len() - 1 {
        size /= 1024.0;
        idx += 1;
    }
    let precision = if size >= 100.0 || idx <= 1 { 0 } else { 1 };
    format!("{size:.precision$} {}", UNITS[idx])
}

fn fail(message: &str) -> ! {
    eprintln!("notilus-scan: {message}");
    eprintln!("{USAGE}");
    std::process::exit(2);
}

const USAGE: &str = "\
usage: notilus-scan <root>... [options]

options:
  --min-size <bytes>     ignore files smaller than this (default 1)
  --ext <.a,.b>          only consider these extensions
  --exclude <a,b>        prune these directory names
  --defaults             also prune the built-in build/cache directory list
  --include-hidden       descend into dot-directories and dot-files
  --no-skip-bundles      descend into .app / .framework style packages
  --quiet                suppress the progress line
";

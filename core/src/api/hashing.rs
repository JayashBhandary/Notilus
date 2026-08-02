//! SHA-256 over file contents.
//!
//! Replaces `duplicate_finder_service.dart:_hashFile` and the two chunked
//! hashers in `services/transfer/file_transfer.dart`. `package:crypto` is a
//! pure-Dart implementation with no access to SHA-NI / NEON; `sha2` compiles
//! down to the hardware instructions where the CPU offers them.

use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

/// Read buffer for whole-file hashing. Large enough that the syscall overhead
/// disappears against the hashing cost, small enough to stay in L2.
const READ_BUF: usize = 256 * 1024;

/// Full SHA-256 of the file at `path`, lowercase hex.
pub fn hash_file(path: String) -> Result<String, String> {
    sha256_file(Path::new(&path)).map_err(|e| format!("{path}: {e}"))
}

/// A cheap content fingerprint: SHA-256 over the first and last `window` bytes
/// plus the file length, lowercase hex.
///
/// This is the early-out the Dart scanner never had. Two files that share a
/// size but differ anywhere near either end are separated after reading a few
/// KB instead of both files end to end — which on a drive full of media is the
/// overwhelming majority of size collisions.
///
/// It is a *filter*, never a verdict: a prefix match still has to be confirmed
/// by [`hash_file`] before two paths are reported as duplicates.
pub fn hash_file_prefix(path: String, window: u64) -> Result<String, String> {
    sha256_head_tail(Path::new(&path), window).map_err(|e| format!("{path}: {e}"))
}

pub(crate) fn sha256_file(path: &Path) -> io::Result<String> {
    let mut reader = BufReader::with_capacity(READ_BUF, File::open(path)?);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; READ_BUF];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(to_hex(&hasher.finalize()))
}

pub(crate) fn sha256_head_tail(path: &Path, window: u64) -> io::Result<String> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let mut hasher = Sha256::new();

    // Bind the length in, so a short file can't collide with a longer one that
    // happens to start and end the same way.
    hasher.update(len.to_le_bytes());

    if len <= window.saturating_mul(2) {
        // Small enough that head+tail would overlap — just hash it all.
        let mut buf = Vec::with_capacity(len as usize);
        file.read_to_end(&mut buf)?;
        hasher.update(&buf);
        return Ok(to_hex(&hasher.finalize()));
    }

    let window = window as usize;
    let mut head = vec![0u8; window];
    file.read_exact(&mut head)?;
    hasher.update(&head);

    let mut tail = vec![0u8; window];
    file.seek(SeekFrom::End(-(window as i64)))?;
    file.read_exact(&mut tail)?;
    hasher.update(&tail);

    Ok(to_hex(&hasher.finalize()))
}

fn to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(name: &str, contents: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join("notilus_core_hash_tests");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut f = File::create(&path).unwrap();
        f.write_all(contents).unwrap();
        f.flush().unwrap();
        path
    }

    #[test]
    fn hashes_match_known_sha256_vectors() {
        let path = temp_file("abc.bin", b"abc");
        assert_eq!(
            sha256_file(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );

        let empty = temp_file("empty.bin", b"");
        assert_eq!(
            sha256_file(&empty).unwrap(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn full_hash_survives_a_file_larger_than_the_read_buffer() {
        let big: Vec<u8> = (0..(READ_BUF * 2 + 1234)).map(|i| (i % 251) as u8).collect();
        let path = temp_file("big.bin", &big);

        let mut expected = Sha256::new();
        expected.update(&big);
        assert_eq!(sha256_file(&path).unwrap(), to_hex(&expected.finalize()));
    }

    #[test]
    fn prefix_hash_separates_files_that_differ_at_either_end() {
        let mut a = vec![7u8; 40_000];
        let mut b = a.clone();
        b[10] = 8; // differs in the head window

        let mut c = a.clone();
        let last = c.len() - 1;
        c[last] = 9; // differs only in the tail window

        a[20_000] = 1; // differs only in the middle — invisible to a prefix hash

        let pa = temp_file("pa.bin", &a);
        let pb = temp_file("pb.bin", &b);
        let pc = temp_file("pc.bin", &c);

        let ha = sha256_head_tail(&pa, 4096).unwrap();
        let hb = sha256_head_tail(&pb, 4096).unwrap();
        let hc = sha256_head_tail(&pc, 4096).unwrap();

        assert_ne!(ha, hb, "a head difference must be caught");
        assert_ne!(ha, hc, "a tail difference must be caught");

        // And the middle-only difference is exactly why this is a filter and
        // not a verdict: the prefixes collide, the full hashes must not.
        let plain = temp_file("plain.bin", &vec![7u8; 40_000]);
        assert_eq!(sha256_head_tail(&plain, 4096).unwrap(), ha);
        assert_ne!(sha256_file(&plain).unwrap(), sha256_file(&pa).unwrap());
    }

    #[test]
    fn prefix_hash_of_a_file_smaller_than_the_window_hashes_everything() {
        let small = temp_file("small.bin", b"hello world");
        let other = temp_file("small2.bin", b"hello worlD");
        assert_ne!(
            sha256_head_tail(&small, 4096).unwrap(),
            sha256_head_tail(&other, 4096).unwrap()
        );
    }

    #[test]
    fn length_is_bound_into_the_prefix_hash() {
        // Same head and tail window, different length.
        let short = temp_file("len_a.bin", &vec![3u8; 9_000]);
        let long = temp_file("len_b.bin", &vec![3u8; 12_000]);
        assert_ne!(
            sha256_head_tail(&short, 1024).unwrap(),
            sha256_head_tail(&long, 1024).unwrap()
        );
    }

    #[test]
    fn missing_files_report_the_path() {
        let err = hash_file("/definitely/not/here.bin".to_string()).unwrap_err();
        assert!(err.contains("/definitely/not/here.bin"), "got: {err}");
    }
}

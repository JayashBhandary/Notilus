//! Archive listing and single-entry extraction.
//!
//! Replaces `_ArchiveView._scan` in `screens/file_preview_screen.dart`, which
//! read the entire archive into memory with `readAsBytes()` and then inflated
//! it with the pure-Dart decoders — on the UI thread, with no `compute()`.
//!
//! The important win is not raw decode speed. It is that **listing a zip never
//! decompresses anything**: the entry table lives in the central directory at
//! the end of the file, so a 2 GB zip lists after reading a few KB. Tar
//! variants are inherently sequential — the entry headers are interleaved with
//! the data — but they stream instead of materialising the whole archive.

use bzip2::read::BzDecoder;
use flate2::read::GzDecoder;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

/// Cap on a single extracted entry, so a zip bomb can't exhaust memory.
const MAX_EXTRACT_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveEntry {
    pub name: String,
    /// Uncompressed size in bytes.
    pub size: u64,
    pub is_dir: bool,
}

/// Lists the entries in the archive at `path`, sorted by name.
///
/// Supports `.zip`/`.jar`, `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2`, and
/// bare `.gz`/`.bz2` (which report the single payload they wrap).
pub fn list_archive(path: String) -> Result<Vec<ArchiveEntry>, String> {
    let mut entries =
        list_inner(Path::new(&path)).map_err(|e| format!("Couldn't read {path}: {e}"))?;
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}

/// Extracts one entry's bytes. Errors if the entry is missing, is a directory,
/// or exceeds [`MAX_EXTRACT_BYTES`].
pub fn extract_archive_entry(path: String, entry_name: String) -> Result<Vec<u8>, String> {
    extract_inner(Path::new(&path), &entry_name)
        .map_err(|e| format!("Couldn't extract {entry_name} from {path}: {e}"))
}

/// How an archive is packaged, derived from its filename.
///
/// Shared with [`crate::api::quick`], which needs the same classification to
/// decide how to unpack an archive in full.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ArchiveKind {
    Zip,
    Tar,
    TarGz,
    TarBz2,
    Gz,
    Bz2,
}

pub(crate) fn classify(path: &Path) -> Option<ArchiveKind> {
    let lower = path.file_name()?.to_string_lossy().to_lowercase();
    // Longest suffixes first: ".tar.gz" must not be read as ".gz".
    let table = [
        (".tar.gz", ArchiveKind::TarGz),
        (".tgz", ArchiveKind::TarGz),
        (".tar.bz2", ArchiveKind::TarBz2),
        (".tbz2", ArchiveKind::TarBz2),
        (".tar", ArchiveKind::Tar),
        (".zip", ArchiveKind::Zip),
        (".jar", ArchiveKind::Zip),
        (".gz", ArchiveKind::Gz),
        (".bz2", ArchiveKind::Bz2),
    ];
    table
        .iter()
        .find(|(suffix, _)| lower.ends_with(suffix))
        .map(|(_, kind)| *kind)
}

fn list_inner(path: &Path) -> io::Result<Vec<ArchiveEntry>> {
    let kind = classify(path).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "unrecognised archive extension")
    })?;

    match kind {
        ArchiveKind::Zip => list_zip(path),
        ArchiveKind::Tar => list_tar(tar::Archive::new(BufReader::new(File::open(path)?))),
        ArchiveKind::TarGz => list_tar(tar::Archive::new(GzDecoder::new(BufReader::new(
            File::open(path)?,
        )))),
        ArchiveKind::TarBz2 => list_tar(tar::Archive::new(BzDecoder::new(BufReader::new(
            File::open(path)?,
        )))),
        ArchiveKind::Gz => Ok(vec![ArchiveEntry {
            name: inner_name(path),
            size: gzip_uncompressed_size(path)?,
            is_dir: false,
        }]),
        ArchiveKind::Bz2 => Ok(vec![ArchiveEntry {
            name: inner_name(path),
            size: drain_count(BzDecoder::new(BufReader::new(File::open(path)?)))?,
            is_dir: false,
        }]),
    }
}

fn list_zip(path: &Path) -> io::Result<Vec<ArchiveEntry>> {
    let file = File::open(path)?;
    let mut archive = zip::ZipArchive::new(BufReader::new(file))
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    let mut out = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        out.push(ArchiveEntry {
            name: entry.name().to_string(),
            size: entry.size(),
            is_dir: entry.is_dir(),
        });
    }
    Ok(out)
}

fn list_tar<R: Read>(mut archive: tar::Archive<R>) -> io::Result<Vec<ArchiveEntry>> {
    let mut out = Vec::new();
    for entry in archive.entries()? {
        let entry = entry?;
        let header = entry.header();
        out.push(ArchiveEntry {
            name: entry.path()?.to_string_lossy().into_owned(),
            size: header.size().unwrap_or(0),
            is_dir: header.entry_type().is_dir(),
        });
    }
    Ok(out)
}

fn extract_inner(path: &Path, entry_name: &str) -> io::Result<Vec<u8>> {
    let kind = classify(path).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "unrecognised archive extension")
    })?;

    match kind {
        ArchiveKind::Zip => {
            let mut archive = zip::ZipArchive::new(BufReader::new(File::open(path)?))
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            let mut entry = archive
                .by_name(entry_name)
                .map_err(|e| io::Error::new(io::ErrorKind::NotFound, e))?;
            if entry.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "entry is a directory",
                ));
            }
            let size = entry.size();
            read_capped(&mut entry, size)
        }
        ArchiveKind::Tar => extract_tar(tar::Archive::new(BufReader::new(File::open(path)?)), entry_name),
        ArchiveKind::TarGz => extract_tar(
            tar::Archive::new(GzDecoder::new(BufReader::new(File::open(path)?))),
            entry_name,
        ),
        ArchiveKind::TarBz2 => extract_tar(
            tar::Archive::new(BzDecoder::new(BufReader::new(File::open(path)?))),
            entry_name,
        ),
        ArchiveKind::Gz => read_capped(
            &mut GzDecoder::new(BufReader::new(File::open(path)?)),
            gzip_uncompressed_size(path)?,
        ),
        ArchiveKind::Bz2 => read_capped(&mut BzDecoder::new(BufReader::new(File::open(path)?)), 0),
    }
}

fn extract_tar<R: Read>(mut archive: tar::Archive<R>, entry_name: &str) -> io::Result<Vec<u8>> {
    for entry in archive.entries()? {
        let mut entry = entry?;
        if entry.path()?.to_string_lossy() != entry_name {
            continue;
        }
        if entry.header().entry_type().is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "entry is a directory",
            ));
        }
        let size = entry.header().size().unwrap_or(0);
        return read_capped(&mut entry, size);
    }
    Err(io::Error::new(io::ErrorKind::NotFound, "no such entry"))
}

/// Reads at most [`MAX_EXTRACT_BYTES`], rejecting an entry that claims — or
/// turns out to be — larger. `declared` is used only to size the buffer.
fn read_capped<R: Read>(reader: &mut R, declared: u64) -> io::Result<Vec<u8>> {
    if declared > MAX_EXTRACT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "entry exceeds the extraction size limit",
        ));
    }
    let mut buf = Vec::with_capacity(declared.min(1024 * 1024) as usize);
    // Read one byte past the cap so an entry that lies about its size is
    // caught rather than silently truncated.
    let read = reader
        .take(MAX_EXTRACT_BYTES + 1)
        .read_to_end(&mut buf)? as u64;
    if read > MAX_EXTRACT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "entry exceeds the extraction size limit",
        ));
    }
    Ok(buf)
}

/// Uncompressed size from the gzip ISIZE trailer — the last 4 bytes of the
/// file — without decompressing. ISIZE is modulo 2^32, so for payloads over
/// 4 GB this is a lower bound; the preview only uses it as a label.
fn gzip_uncompressed_size(path: &Path) -> io::Result<u64> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    if len < 4 {
        return Ok(0);
    }
    file.seek(SeekFrom::End(-4))?;
    let mut trailer = [0u8; 4];
    file.read_exact(&mut trailer)?;
    Ok(u32::from_le_bytes(trailer) as u64)
}

/// Streams a reader to completion and reports how many bytes came out.
fn drain_count<R: Read>(mut reader: R) -> io::Result<u64> {
    io::copy(&mut reader, &mut io::sink())
}

pub(crate) fn inner_name(path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_archive_tests")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn build_zip(path: &Path) {
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let opts: zip::write::FileOptions<'_, ()> = zip::write::FileOptions::default();
        zip.add_directory("docs/", opts).unwrap();
        zip.start_file("docs/readme.txt", opts).unwrap();
        zip.write_all(b"hello from inside the zip").unwrap();
        zip.start_file("data.bin", opts).unwrap();
        zip.write_all(&vec![7u8; 5000]).unwrap();
        zip.finish().unwrap();
    }

    fn build_tar_gz(path: &Path) {
        let file = File::create(path).unwrap();
        let enc = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        let mut builder = tar::Builder::new(enc);

        let mut header = tar::Header::new_gnu();
        header.set_size(11);
        header.set_mode(0o644);
        header.set_cksum();
        builder
            .append_data(&mut header, "greeting.txt", &b"hello world"[..])
            .unwrap();
        builder.into_inner().unwrap().finish().unwrap();
    }

    #[test]
    fn lists_zip_entries_with_sizes_and_directory_flags() {
        let dir = scratch("zip");
        let path = dir.join("sample.zip");
        build_zip(&path);

        let entries = list_archive(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(entries.len(), 3);
        // Sorted by name.
        assert_eq!(entries[0].name, "data.bin");
        assert_eq!(entries[0].size, 5000);
        assert!(!entries[0].is_dir);
        assert_eq!(entries[1].name, "docs/");
        assert!(entries[1].is_dir);
        assert_eq!(entries[2].name, "docs/readme.txt");
        assert_eq!(entries[2].size, 25);
    }

    #[test]
    fn extracts_a_named_zip_entry() {
        let dir = scratch("zip_extract");
        let path = dir.join("sample.zip");
        build_zip(&path);

        let bytes = extract_archive_entry(
            path.to_string_lossy().into_owned(),
            "docs/readme.txt".into(),
        )
        .unwrap();
        assert_eq!(bytes, b"hello from inside the zip");
    }

    #[test]
    fn extracting_a_directory_or_a_missing_entry_is_an_error() {
        let dir = scratch("zip_errors");
        let path = dir.join("sample.zip");
        build_zip(&path);
        let p = path.to_string_lossy().into_owned();

        assert!(extract_archive_entry(p.clone(), "docs/".into()).is_err());
        let err = extract_archive_entry(p, "nope.txt".into()).unwrap_err();
        assert!(err.contains("nope.txt"), "got: {err}");
    }

    #[test]
    fn lists_and_extracts_from_a_tar_gz() {
        let dir = scratch("targz");
        let path = dir.join("bundle.tar.gz");
        build_tar_gz(&path);
        let p = path.to_string_lossy().into_owned();

        let entries = list_archive(p.clone()).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "greeting.txt");
        assert_eq!(entries[0].size, 11);

        let bytes = extract_archive_entry(p, "greeting.txt".into()).unwrap();
        assert_eq!(bytes, b"hello world");
    }

    #[test]
    fn a_bare_gzip_reports_its_single_payload() {
        let dir = scratch("gz");
        let path = dir.join("notes.txt.gz");
        let payload = b"a plain gzipped file";
        {
            let file = File::create(&path).unwrap();
            let mut enc = flate2::write::GzEncoder::new(file, flate2::Compression::default());
            enc.write_all(payload).unwrap();
            enc.finish().unwrap();
        }

        let entries = list_archive(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "notes.txt");
        assert_eq!(entries[0].size, payload.len() as u64);
        assert!(!entries[0].is_dir);
    }

    #[test]
    fn tar_gz_is_not_misread_as_a_bare_gz() {
        // ".tar.gz" ends with ".gz"; classification must prefer the longer
        // suffix or the listing collapses to one bogus entry.
        assert_eq!(classify(Path::new("/x/a.tar.gz")), Some(ArchiveKind::TarGz));
        assert_eq!(classify(Path::new("/x/a.tgz")), Some(ArchiveKind::TarGz));
        assert_eq!(classify(Path::new("/x/a.gz")), Some(ArchiveKind::Gz));
        assert_eq!(classify(Path::new("/x/a.tar.bz2")), Some(ArchiveKind::TarBz2));
        assert_eq!(classify(Path::new("/x/a.bz2")), Some(ArchiveKind::Bz2));
        assert_eq!(classify(Path::new("/x/a.jar")), Some(ArchiveKind::Zip));
        assert_eq!(classify(Path::new("/x/a.txt")), None);
    }

    #[test]
    fn an_unrecognised_extension_is_a_readable_error() {
        let dir = scratch("unknown");
        let path = dir.join("mystery.dat");
        std::fs::write(&path, b"not an archive").unwrap();
        let err = list_archive(path.to_string_lossy().into_owned()).unwrap_err();
        assert!(err.contains("mystery.dat"), "got: {err}");
    }

    #[test]
    fn a_corrupt_zip_reports_an_error_rather_than_panicking() {
        let dir = scratch("corrupt");
        let path = dir.join("broken.zip");
        std::fs::write(&path, b"PK\x03\x04 and then garbage").unwrap();
        assert!(list_archive(path.to_string_lossy().into_owned()).is_err());
    }
}

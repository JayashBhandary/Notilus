//! Thumbnails: one encoder, and names that travel with the data.
//!
//! # Why the names matter more than the encoder
//!
//! A thumbnail cache keyed on an absolute path is worthless the moment the same
//! files are seen from somewhere else. `/media/jayash/photos` and
//! `/Volumes/photos` are the same external drive; `notilus://s3/bucket/trip`
//! is the same folder from three different laptops. Every one of them used to
//! re-decode every JPEG, because the key said they were different files.
//!
//! So the key here holds **no path** — only the entry's own name, size and
//! modification time. That makes a thumbnail portable: it can live in a hidden
//! `.thumbs` folder *beside* the data, and any machine that reaches that folder
//! recognises it. Plug the drive into another laptop, or point a second Notilus
//! at the same bucket, and the thumbnails are already there.
//!
//! # The name is the whole record
//!
//! ```text
//! .thumbs/<fnv1a of lowercased name>_<size>_<mtime seconds>_<dim>.webp
//! ```
//!
//! There is deliberately no index file. One directory listing — a `readdir`
//! locally, a single prefixed `LIST` on S3 — answers "which of these 400 files
//! already have a thumbnail" without opening anything. A name that matches
//! exactly is a hit; one whose leading hash matches but whose tail differs is a
//! thumbnail of a version of the file that no longer exists, and can be swept.
//!
//! It also means two machines writing into the same share cannot corrupt each
//! other's work: there is no shared file to read, modify and write back. Every
//! write is a single create, and a create of a name that already exists is
//! writing identical content.
//!
//! # Time in seconds
//!
//! Sub-second precision is the one thing sources disagree on. SMB reports
//! 100-nanosecond ticks, S3's `LastModified` is whole seconds, FAT32 rounds to
//! two. Keying on milliseconds would make a thumbnail written from an SMB
//! mount permanently invisible to the same folder reached over S3. Seconds is
//! the greatest common precision.

use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageReader, Limits};
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::Path;

/// The hidden folder thumbnails live in, beside the data they describe.
pub const SIDECAR_DIR: &str = ".thumbs";

/// The extension every stored thumbnail carries.
pub const SIDECAR_EXT: &str = "webp";

/// The one size stored on disk.
///
/// Surfaces want 96, 320 and 640 pixels. Storing all three would triple the
/// footprint of a folder's `.thumbs` and — worse for a shared source — mean a
/// phone browsing at 96px generating a whole second set that the laptop at
/// 320px never uses. One master, downscaled in memory per surface, is smaller
/// and shared by every device.
pub const MASTER_DIM: u32 = 512;

/// WebP quality. 80 is the knee of the curve: a 512px photo lands around
/// 25-45 KB, and going higher buys detail nobody sees at thumbnail size.
const QUALITY: f32 = 80.0;

/// Ceiling on what a source is allowed to decode to.
///
/// A thumbnail source can come from a share other people write to, and a few
/// hundred bytes of header can declare 60000x60000 pixels. Without a limit that
/// is a 14 GB allocation on the strength of a stranger's say-so.
const MAX_SOURCE_PIXELS: u64 = 80_000_000;

/// Largest `.thumbs` entry worth reading.
///
/// Anything Notilus wrote is tens of kilobytes. A megabyte-plus entry in a
/// shared `.thumbs` was not written by this code, and is not worth decoding to
/// find out what it is.
pub const MAX_SIDECAR_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThumbnailInfo {
    /// Where the thumbnail was written.
    pub path: String,
    pub width: u32,
    pub height: u32,
    /// True when an existing cache file was reused and nothing was decoded.
    pub from_cache: bool,
}

/// An encoded thumbnail that hasn't been written anywhere yet.
///
/// What a remote sidecar needs: the bytes go out as an upload, not to a local
/// path. Also what a rendered PDF page or video frame becomes on its way into
/// `.thumbs`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThumbnailBytes {
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Decodes `src`, fits it inside a `max_dim` box preserving aspect ratio, and
/// writes a WebP to `dst`.
///
/// If `dst` already exists it is reused untouched — callers build `dst` from
/// [`sidecar_name`] or [`cache_key`], both of which fold in size and
/// modification time, so an edited source produces a different filename.
pub fn thumbnail_image(
    src: String,
    dst: String,
    max_dim: u32,
) -> Result<ThumbnailInfo, String> {
    generate(Path::new(&src), Path::new(&dst), max_dim)
        .map_err(|e| format!("Couldn't thumbnail {src}: {e}"))
}

/// Decodes `src` and returns the encoded thumbnail without writing it.
pub fn thumbnail_bytes(src: String, max_dim: u32) -> Result<ThumbnailBytes, String> {
    let image = decode_path(Path::new(&src)).map_err(|e| format!("Couldn't read {src}: {e}"))?;
    encode(&fit(image, max_dim)?)
}

/// Re-encodes an image already in memory as a thumbnail.
///
/// The way a rendered PDF page or an extracted video frame — both of which
/// arrive as PNG from an external tool — becomes something small enough to
/// leave in a `.thumbs` folder. Also the cloud path: bytes that were downloaded
/// to be previewed anyway are thumbnailed on the way past.
pub fn thumbnail_from_bytes(
    source: Vec<u8>,
    max_dim: u32,
) -> Result<ThumbnailBytes, String> {
    let image = decode_reader(ImageReader::new(Cursor::new(source)))
        .map_err(|e| format!("Couldn't read the image: {e}"))?;
    encode(&fit(image, max_dim)?)
}

/// The `.thumbs` filename for one directory entry.
///
/// `name` is the entry's own name — never a path. Two folders holding a
/// `holiday.jpg` of the same size and time get the same filename, but they get
/// it in their own `.thumbs`, so nothing collides.
pub fn sidecar_name(name: String, size: u64, modified_ms: i64, dim: u32) -> String {
    let seconds = modified_ms.div_euclid(1000);
    format!(
        "{}{size}_{seconds}_{dim}.{SIDECAR_EXT}",
        sidecar_prefix(name)
    )
}

/// The leading, name-only part of a [`sidecar_name`], including its separator.
///
/// Everything in a `.thumbs` folder starting with this describes the same entry
/// name. Exactly one of them — at most — is current; the rest are thumbnails of
/// versions that have since been edited or replaced, and are safe to delete.
pub fn sidecar_prefix(name: String) -> String {
    format!("{}_", fnv1a_hex(&name.to_lowercase()))
}

/// A stable central-cache filename for `(path, mtime, size, dim)`.
///
/// Still keyed on the absolute path, deliberately: this is the fallback for
/// sources nothing can be written to, where there is no sharing to be had and
/// the path is the only stable identity available.
pub fn cache_key(path: String, modified_ms: i64, size: u64, dim: u32) -> String {
    fnv1a_hex(&format!("{path}|{modified_ms}|{size}|{dim}"))
}

/// FNV-1a, 64-bit, as sixteen lower-case hex digits.
///
/// Mirrored in `lib/services/thumbnails/sidecar_naming.dart`, which has to
/// produce the same name synchronously while a listing is being built. Both
/// sides are pinned to the published `"abc"` vector by a test, because Dart's
/// integers are signed and the obvious implementation there silently emits a
/// minus sign for half of all inputs.
///
/// Not a security hash. A collision costs one redundant decode.
fn fnv1a_hex(value: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    for byte in value.bytes() {
        h ^= byte as u64;
        h = h.wrapping_mul(PRIME);
    }
    format!("{h:016x}")
}

// ── the encoder ────────────────────────────────────────────────────────────

fn generate(src: &Path, dst: &Path, max_dim: u32) -> Result<ThumbnailInfo, String> {
    if let Ok(meta) = std::fs::metadata(dst) {
        if meta.is_file() && meta.len() > 0 {
            // Trust the cache: the key already encodes source identity.
            if let Ok(dims) = image::image_dimensions(dst) {
                return Ok(ThumbnailInfo {
                    path: dst.to_string_lossy().into_owned(),
                    width: dims.0,
                    height: dims.1,
                    from_cache: true,
                });
            }
        }
    }

    let scaled = fit(decode_path(src)?, max_dim)?;
    let encoded = encode(&scaled)?;

    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    // Written under a neighbouring name and moved into place, so a reader that
    // arrives mid-write — another Notilus on the same share — never sees a
    // half-file and cache it as real.
    let staging = dst.with_extension("webp.part");
    std::fs::write(&staging, &encoded.bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&staging, dst).map_err(|e| {
        let _ = std::fs::remove_file(&staging);
        e.to_string()
    })?;

    Ok(ThumbnailInfo {
        path: dst.to_string_lossy().into_owned(),
        width: encoded.width,
        height: encoded.height,
        from_cache: false,
    })
}

fn decode_path(src: &Path) -> Result<DynamicImage, String> {
    decode_reader(ImageReader::open(src).map_err(|e| e.to_string())?)
}

fn decode_reader<R: std::io::BufRead + std::io::Seek>(
    reader: ImageReader<R>,
) -> Result<DynamicImage, String> {
    let mut limits = Limits::default();
    limits.max_alloc = Some(MAX_SOURCE_PIXELS * 4);
    let mut reader = reader.with_guessed_format().map_err(|e| e.to_string())?;
    reader.limits(limits);

    let mut decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    let (w, h) = decoder.dimensions();
    if u64::from(w) * u64::from(h) > MAX_SOURCE_PIXELS {
        return Err(format!("{w}x{h} is larger than this will decode"));
    }
    // JPEGs from phones are almost always stored rotated with an EXIF tag;
    // ignoring it yields sideways thumbnails.
    let orientation = decoder.orientation().map_err(|e| e.to_string())?;
    let mut image = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    image.apply_orientation(orientation);
    Ok(image)
}

fn fit(image: DynamicImage, max_dim: u32) -> Result<DynamicImage, String> {
    if max_dim == 0 {
        return Err("max_dim must be greater than zero".into());
    }
    // `thumbnail` is a fast box filter for big reductions; `resize` with
    // Lanczos3 looks better when barely scaling down.
    let longest = image.width().max(image.height());
    if longest <= max_dim {
        // Already small enough. Re-encoding at a larger size would only invent
        // pixels and cost bytes.
        return Ok(image);
    }
    Ok(if longest > max_dim * 2 {
        image.thumbnail(max_dim, max_dim)
    } else {
        image.resize(max_dim, max_dim, FilterType::Lanczos3)
    })
}

fn encode(image: &DynamicImage) -> Result<ThumbnailBytes, String> {
    let (width, height) = (image.width(), image.height());
    if width == 0 || height == 0 {
        return Err("the image has no pixels".into());
    }
    // libwebp takes 8-bit RGB or RGBA and nothing else, so anything paletted,
    // 16-bit or greyscale is converted rather than refused.
    let bytes = if image.color().has_alpha() {
        let rgba = image.to_rgba8();
        webp::Encoder::from_rgba(&rgba, width, height)
            .encode(QUALITY)
            .to_vec()
    } else {
        let rgb = image.to_rgb8();
        webp::Encoder::from_rgb(&rgb, width, height)
            .encode(QUALITY)
            .to_vec()
    };
    if bytes.is_empty() {
        return Err("the WebP encoder produced nothing".into());
    }
    Ok(ThumbnailBytes {
        bytes,
        width,
        height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("notilus_core_thumb_tests")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_png(path: &Path, w: u32, h: u32) {
        let mut img = RgbaImage::new(w, h);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = Rgba([(x % 256) as u8, (y % 256) as u8, 128, 255]);
        }
        img.save_with_format(path, ImageFormat::Png).unwrap();
    }

    #[test]
    fn downscales_and_preserves_aspect_ratio() {
        let dir = scratch("basic");
        let src = dir.join("wide.png");
        write_png(&src, 800, 400);
        let dst = dir.join("thumb.webp");

        let info = thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            100,
        )
        .unwrap();

        assert!(!info.from_cache);
        assert_eq!(info.width, 100);
        assert_eq!(info.height, 50, "2:1 source must stay 2:1");
        assert!(dst.exists());
    }

    #[test]
    fn a_tall_image_is_bounded_by_its_height() {
        let dir = scratch("tall");
        let src = dir.join("tall.png");
        write_png(&src, 200, 600);
        let dst = dir.join("thumb.webp");

        let info = thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            120,
        )
        .unwrap();
        assert_eq!(info.height, 120);
        assert_eq!(info.width, 40);
    }

    #[test]
    fn what_is_written_is_a_readable_webp() {
        let dir = scratch("webp");
        let src = dir.join("src.png");
        write_png(&src, 400, 300);
        let dst = dir.join("thumb.webp");

        thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            MASTER_DIM,
        )
        .unwrap();

        let reader = ImageReader::open(&dst)
            .unwrap()
            .with_guessed_format()
            .unwrap();
        assert_eq!(reader.format(), Some(ImageFormat::WebP));
    }

    #[test]
    fn an_image_smaller_than_the_box_is_not_enlarged() {
        let dir = scratch("small");
        let src = dir.join("tiny.png");
        write_png(&src, 48, 32);
        let dst = dir.join("thumb.webp");

        let info = thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            MASTER_DIM,
        )
        .unwrap();
        assert_eq!((info.width, info.height), (48, 32));
    }

    #[test]
    fn a_lossy_thumbnail_is_small_enough_to_leave_on_someone_elses_drive() {
        // Photo-like content: smooth gradients plus grain, which is where a
        // lossless encoder loses badly. The point of the format choice.
        let dir = scratch("size");
        let src = dir.join("photo.png");
        let mut img = RgbaImage::new(2000, 1500);
        let mut seed: u32 = 7;
        for (x, y, px) in img.enumerate_pixels_mut() {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            let n = ((seed >> 16) & 0x1f) as u8;
            *px = Rgba([
                ((x * 255 / 2000) as u8).saturating_add(n),
                ((y * 255 / 1500) as u8).saturating_add(n),
                128u8.saturating_add(n),
                255,
            ]);
        }
        img.save_with_format(&src, ImageFormat::Png).unwrap();

        let out = thumbnail_bytes(src.to_string_lossy().into_owned(), MASTER_DIM).unwrap();
        assert_eq!(out.width, MASTER_DIM);
        assert!(
            out.bytes.len() < 80 * 1024,
            "a 512px thumbnail should be tens of KB, got {}",
            out.bytes.len()
        );
    }

    #[test]
    fn an_existing_thumbnail_is_reused_rather_than_regenerated() {
        let dir = scratch("cached");
        let src = dir.join("src.png");
        write_png(&src, 400, 400);
        let dst = dir.join("thumb.webp");
        let s = src.to_string_lossy().into_owned();
        let d = dst.to_string_lossy().into_owned();

        let first = thumbnail_image(s.clone(), d.clone(), 64).unwrap();
        assert!(!first.from_cache);

        let second = thumbnail_image(s, d, 64).unwrap();
        assert!(second.from_cache);
        assert_eq!(second.width, first.width);
    }

    #[test]
    fn nothing_is_left_behind_when_a_write_succeeds() {
        let dir = scratch("staging");
        let src = dir.join("src.png");
        write_png(&src, 100, 100);
        let dst = dir.join("out/thumb.webp");

        thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            64,
        )
        .unwrap();

        let left: Vec<_> = std::fs::read_dir(dir.join("out"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(left, vec!["thumb.webp".to_string()]);
    }

    #[test]
    fn a_rendered_page_can_be_re_encoded_without_touching_the_disk() {
        let dir = scratch("frombytes");
        let src = dir.join("page.png");
        write_png(&src, 900, 1200);
        let png = std::fs::read(&src).unwrap();

        let out = thumbnail_from_bytes(png, MASTER_DIM).unwrap();
        assert_eq!(out.height, MASTER_DIM);
        assert_eq!(out.width, 384);
        assert!(!out.bytes.is_empty());
    }

    #[test]
    fn a_non_image_source_is_a_readable_error_not_a_panic() {
        let dir = scratch("garbage");
        let src = dir.join("notanimage.png");
        std::fs::write(&src, b"definitely not a PNG").unwrap();
        let dst = dir.join("thumb.webp");

        let err = thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            64,
        )
        .unwrap_err();
        assert!(err.contains("notanimage.png"), "got: {err}");
    }

    #[test]
    fn an_absurdly_large_source_is_refused_before_it_is_allocated() {
        // A real, complete, 300-byte PNG whose header claims 40000x40000.
        // Decoding it would ask for over 6 GB, and a `.thumbs` folder on a
        // share other people write to is exactly where such a file turns up.
        let dir = scratch("bomb");
        let src = dir.join("bomb.png");
        write_png(&src, 8, 8);
        let mut bytes = std::fs::read(&src).unwrap();
        // IHDR's width and height are the first two fields of its data, which
        // starts 16 bytes in: 8 of signature, 4 of length, 4 of type.
        bytes[16..20].copy_from_slice(&40_000u32.to_be_bytes());
        bytes[20..24].copy_from_slice(&40_000u32.to_be_bytes());
        let crc = crc32(&bytes[12..29]).to_be_bytes();
        bytes[29..33].copy_from_slice(&crc);
        std::fs::write(&src, &bytes).unwrap();

        let err =
            thumbnail_bytes(src.to_string_lossy().into_owned(), MASTER_DIM).unwrap_err();
        assert!(err.contains("40000x40000"), "got: {err}");
    }

    /// CRC-32 as PNG uses it, to re-stamp the chunk the test above rewrites.
    fn crc32(data: &[u8]) -> u32 {
        let mut crc = 0xffff_ffffu32;
        for byte in data {
            crc ^= *byte as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }

    #[test]
    fn a_zero_dimension_is_rejected() {
        let dir = scratch("zero");
        let src = dir.join("src.png");
        write_png(&src, 10, 10);
        assert!(thumbnail_image(
            src.to_string_lossy().into_owned(),
            dir.join("t.webp").to_string_lossy().into_owned(),
            0,
        )
        .is_err());
    }

    // ── names ──────────────────────────────────────────────────────────────

    #[test]
    fn a_sidecar_name_holds_no_path_so_it_travels() {
        let here = sidecar_name("holiday.JPG".into(), 4096, 1_700_000_000_000, 512);
        assert!(here.ends_with(".webp"));
        assert!(!here.contains('/'), "a name must be usable as a filename");

        // The same entry, seen through a different mount point or protocol.
        let there = sidecar_name("holiday.jpg".into(), 4096, 1_700_000_000_000, 512);
        assert_eq!(here, there, "case and location must not change the name");
    }

    #[test]
    fn every_part_of_the_identity_changes_the_name() {
        let base = sidecar_name("a.png".into(), 100, 1_000_000, 512);
        assert_ne!(base, sidecar_name("b.png".into(), 100, 1_000_000, 512));
        assert_ne!(base, sidecar_name("a.png".into(), 101, 1_000_000, 512));
        assert_ne!(base, sidecar_name("a.png".into(), 100, 2_000_000, 512));
        assert_ne!(base, sidecar_name("a.png".into(), 100, 1_000_000, 256));
    }

    #[test]
    fn sub_second_precision_is_dropped_so_two_sources_agree() {
        // The same file over SMB (100ns ticks) and over S3 (whole seconds).
        let smb = sidecar_name("a.png".into(), 10, 1_700_000_000_123, 512);
        let s3 = sidecar_name("a.png".into(), 10, 1_700_000_000_000, 512);
        assert_eq!(smb, s3);
    }

    #[test]
    fn a_stale_thumbnail_is_recognisable_by_its_prefix() {
        let prefix = sidecar_prefix("a.png".into());
        let current = sidecar_name("a.png".into(), 100, 1_000_000, 512);
        let edited = sidecar_name("a.png".into(), 250, 9_000_000, 512);
        let other = sidecar_name("b.png".into(), 100, 1_000_000, 512);

        assert!(current.starts_with(&prefix));
        assert!(edited.starts_with(&prefix), "same entry, older version");
        assert!(!other.starts_with(&prefix));
        assert_ne!(current, edited);
    }

    #[test]
    fn a_time_before_the_epoch_still_rounds_downwards() {
        // `div_euclid` rather than `/`, which truncates towards zero and would
        // put -1500ms and -500ms in the same second as +500ms.
        let a = sidecar_name("a".into(), 1, -1500, 512);
        let b = sidecar_name("a".into(), 1, -500, 512);
        let c = sidecar_name("a".into(), 1, 500, 512);
        assert_ne!(a, b);
        assert_ne!(b, c);
    }

    #[test]
    fn cache_keys_change_with_every_input() {
        let base = cache_key("/a/b.png".into(), 100, 200, 64);
        assert_eq!(base.len(), 16);
        assert_eq!(base, cache_key("/a/b.png".into(), 100, 200, 64));

        assert_ne!(base, cache_key("/a/c.png".into(), 100, 200, 64));
        assert_ne!(base, cache_key("/a/b.png".into(), 101, 200, 64));
        assert_ne!(base, cache_key("/a/b.png".into(), 100, 201, 64));
        assert_ne!(base, cache_key("/a/b.png".into(), 100, 200, 128));
    }

    #[test]
    fn the_hash_matches_the_published_vector_and_so_the_dart_side() {
        // FNV-1a 64 over "abc". `sidecar_naming_test.dart` asserts the same
        // string, which is what keeps a name generated in Dart and a name
        // generated here pointing at one file.
        assert_eq!(fnv1a_hex("abc"), "e71fa2190541574b");
        assert_eq!(fnv1a_hex(""), "cbf29ce484222325");
        assert_eq!(sidecar_prefix("abc".into()), "e71fa2190541574b_");
    }
}

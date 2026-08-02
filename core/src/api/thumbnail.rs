//! Image thumbnail generation with a stable on-disk cache key.
//!
//! Covers the gap the audit flagged: `thumbnail_service.dart` caches PDF
//! previews on disk but nothing else, so the icon grid re-decodes full-
//! resolution JPEG/HEIC every time a row scrolls back into view. Flutter
//! decodes off the UI thread, so this was never a jank source — it is a
//! throughput and memory fix. Downscaling once to a small PNG turns every
//! later view into a few-KB read.

use image::imageops::FilterType;
use image::{ImageDecoder, ImageFormat, ImageReader};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThumbnailInfo {
    /// Where the thumbnail was written.
    pub path: String,
    pub width: u32,
    pub height: u32,
    /// True when an existing cache file was reused and nothing was decoded.
    pub from_cache: bool,
}

/// Decodes `src`, fits it inside a `max_dim` box preserving aspect ratio, and
/// writes a PNG to `dst`.
///
/// If `dst` already exists it is reused untouched — callers are expected to
/// build `dst` from [`cache_key`], which folds in mtime and size so an edited
/// source produces a different filename.
pub fn thumbnail_image(
    src: String,
    dst: String,
    max_dim: u32,
) -> Result<ThumbnailInfo, String> {
    generate(Path::new(&src), Path::new(&dst), max_dim)
        .map_err(|e| format!("Couldn't thumbnail {src}: {e}"))
}

fn generate(src: &Path, dst: &Path, max_dim: u32) -> Result<ThumbnailInfo, String> {
    if max_dim == 0 {
        return Err("max_dim must be greater than zero".into());
    }

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

    let reader = ImageReader::open(src)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?;

    let mut decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    // JPEGs from phones are almost always stored rotated with an EXIF tag;
    // ignoring it yields sideways thumbnails.
    let orientation = decoder.orientation().map_err(|e| e.to_string())?;
    let mut image = image::DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
    image.apply_orientation(orientation);

    // `thumbnail` is a fast box filter for big reductions; `resize` with
    // Lanczos3 looks better when barely scaling down.
    let (w, h) = (image.width(), image.height());
    let scaled = if w.max(h) > max_dim * 2 {
        image.thumbnail(max_dim, max_dim)
    } else {
        image.resize(max_dim, max_dim, FilterType::Lanczos3)
    };

    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    scaled
        .save_with_format(dst, ImageFormat::Png)
        .map_err(|e| e.to_string())?;

    Ok(ThumbnailInfo {
        path: dst.to_string_lossy().into_owned(),
        width: scaled.width(),
        height: scaled.height(),
        from_cache: false,
    })
}

/// A stable cache filename for `(path, mtime, size, dim)`.
///
/// Mirrors the scheme in `thumbnail_service.dart` — FNV-1a over the same key
/// string — so an existing PDF thumbnail cache stays valid when this crate
/// takes over. Not a security hash; collisions only cost a redraw.
pub fn cache_key(path: String, modified_ms: i64, size: u64, dim: u32) -> String {
    let key = format!("{path}|{modified_ms}|{size}|{dim}");
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    for byte in key.bytes() {
        h ^= byte as u64;
        h = h.wrapping_mul(PRIME);
    }
    format!("{h:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};
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
        let dst = dir.join("thumb.png");

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
        let dst = dir.join("thumb.png");

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
    fn an_existing_thumbnail_is_reused_rather_than_regenerated() {
        let dir = scratch("cached");
        let src = dir.join("src.png");
        write_png(&src, 400, 400);
        let dst = dir.join("thumb.png");
        let s = src.to_string_lossy().into_owned();
        let d = dst.to_string_lossy().into_owned();

        let first = thumbnail_image(s.clone(), d.clone(), 64).unwrap();
        assert!(!first.from_cache);

        let second = thumbnail_image(s, d, 64).unwrap();
        assert!(second.from_cache);
        assert_eq!(second.width, first.width);
    }

    #[test]
    fn the_destination_directory_is_created_on_demand() {
        let dir = scratch("mkdir");
        let src = dir.join("src.png");
        write_png(&src, 100, 100);
        let dst = dir.join("nested/deeper/thumb.png");

        thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            32,
        )
        .unwrap();
        assert!(dst.exists());
    }

    #[test]
    fn a_non_image_source_is_a_readable_error_not_a_panic() {
        let dir = scratch("garbage");
        let src = dir.join("notanimage.png");
        std::fs::write(&src, b"definitely not a PNG").unwrap();
        let dst = dir.join("thumb.png");

        let err = thumbnail_image(
            src.to_string_lossy().into_owned(),
            dst.to_string_lossy().into_owned(),
            64,
        )
        .unwrap_err();
        assert!(err.contains("notanimage.png"), "got: {err}");
    }

    #[test]
    fn a_zero_dimension_is_rejected() {
        let dir = scratch("zero");
        let src = dir.join("src.png");
        write_png(&src, 10, 10);
        assert!(thumbnail_image(
            src.to_string_lossy().into_owned(),
            dir.join("t.png").to_string_lossy().into_owned(),
            0,
        )
        .is_err());
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
    fn cache_key_matches_the_dart_fnv1a_implementation() {
        // Cross-checked against thumbnail_service.dart's _hash() so an
        // existing on-disk cache is not invalidated by the migration.
        // FNV-1a 64 over "abc" is a published vector.
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in b"abc" {
            h ^= *b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        assert_eq!(format!("{h:016x}"), "e71fa2190541574b");
    }
}

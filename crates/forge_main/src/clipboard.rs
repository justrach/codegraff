//! System clipboard helpers and image-attachment registry for the REPL.
//!
//! Clipboard images captured via Ctrl+V (see [`crate::editor::ForgeEditMode`])
//! are resized and stored as compressed image files under `~/forge/clipboard/`
//! and registered in a per-process [`ImageRegistry`]. Each registered image gets a small
//! 1-indexed slot — 1, 2, 3 — and the user sees a tidy `[Image N]` chip
//! in the input buffer instead of the long file path.
//!
//! At message-submit time, [`expand_image_chips`] rewrites every recognised
//! `[Image N]` token in the buffer to the canonical `@[<absolute-path>]`
//! attachment syntax, so the existing `forge_domain::Attachment` pipeline
//! handles it without any further plumbing.

use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};

use anyhow::Context;

/// In-process registry of clipboard images, indexed by the 1-based slot the
/// user sees as `[Image N]`. Lifetime is the process — counters do not reset
/// on `:new`, which matches the simplicity of this v1 chip approach. A future
/// iteration may scope the registry per-conversation.
static REGISTRY: LazyLock<Mutex<Vec<PathBuf>>> = LazyLock::new(|| Mutex::new(Vec::new()));

const CLIPBOARD_IMAGE_MAX_EDGE: u32 = 1600;
const CLIPBOARD_IMAGE_JPEG_QUALITY: u8 = 82;

/// Result of a successful clipboard image capture.
#[derive(Debug, Clone)]
pub struct CapturedImage {
    /// 1-indexed slot in [`REGISTRY`]; rendered as `[Image {slot}]` in the
    /// input buffer.
    pub slot: usize,
}

/// Attempts to capture an image from the system clipboard, write it as a
/// compressed file under `~/forge/clipboard/<8hex>.<format>`, and register it
/// for the `[Image N]` chip syntax.
///
/// Returns `Ok(Some(captured))` if an image was captured and successfully
/// written, `Ok(None)` if the clipboard does not currently hold an image
/// (or contains an empty image), and `Err` only for unexpected failures
/// (resize/encoding error, IO error). Callers should treat `Ok(None)` as the
/// normal "no image, fall back to text paste" path.
pub fn capture_clipboard_image() -> anyhow::Result<Option<CapturedImage>> {
    let mut clipboard = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(_) => return Ok(None),
    };

    let img_data = match clipboard.get_image() {
        Ok(d) => d,
        Err(_) => return Ok(None),
    };

    if img_data.width == 0 || img_data.height == 0 {
        return Ok(None);
    }

    let width =
        u32::try_from(img_data.width).context("clipboard image width does not fit in u32")?;
    let height =
        u32::try_from(img_data.height).context("clipboard image height does not fit in u32")?;
    let bytes: Vec<u8> = img_data.bytes.into_owned();

    let img = image::RgbaImage::from_raw(width, height, bytes)
        .context("clipboard image bytes did not match width*height*4")?;

    let encoded = encode_clipboard_image(&img)?;

    // Save under `~/forge/clipboard/<8hex>.<format>`. Falls back to the system
    // temp dir when the home directory is unavailable (sandboxed builds,
    // CI). The user-facing chip uses the registry slot, not the filename,
    // so the on-disk name only matters for debugging.
    let dir = clipboard_dir().unwrap_or_else(std::env::temp_dir);
    if let Err(err) = std::fs::create_dir_all(&dir) {
        tracing::debug!(
            error = %err,
            path = %dir.display(),
            "could not create clipboard dir; falling back to system temp"
        );
    }
    let id = uuid::Uuid::new_v4().simple().to_string();
    let short = id.get(..8).unwrap_or(&id);
    let path = dir.join(format!("{short}.{}", encoded.extension));
    std::fs::write(&path, &encoded.bytes)
        .context("failed to write compressed clipboard image to disk")?;
    tracing::debug!(
        path = %path.display(),
        width = encoded.width,
        height = encoded.height,
        format = encoded.extension,
        "saved compressed clipboard image"
    );

    let mut reg = REGISTRY.lock().expect("clipboard registry mutex poisoned");
    reg.push(path);
    let slot = reg.len();
    Ok(Some(CapturedImage { slot }))
}

/// Returns `~/forge/clipboard/`. Matches the existing `~/forge/` config
/// directory used elsewhere in graff (see
/// `forge_config::ConfigReader::base_path`). Returns `None` when no home
/// directory can be resolved.
fn clipboard_dir() -> Option<PathBuf> {
    Some(dirs::home_dir()?.join("forge").join("clipboard"))
}

#[derive(Debug)]
struct EncodedClipboardImage {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
    extension: &'static str,
}

fn encode_clipboard_image(img: &image::RgbaImage) -> anyhow::Result<EncodedClipboardImage> {
    encode_clipboard_image_with_limits(img, CLIPBOARD_IMAGE_MAX_EDGE, CLIPBOARD_IMAGE_JPEG_QUALITY)
}

fn encode_clipboard_image_with_limits(
    img: &image::RgbaImage,
    max_edge: u32,
    jpeg_quality: u8,
) -> anyhow::Result<EncodedClipboardImage> {
    let source_width = img.width();
    let source_height = img.height();
    let (width, height) = constrained_dimensions(source_width, source_height, max_edge.max(1));
    let rgba = resized_rgba_pixels(img, width, height)?;

    if has_transparency(&rgba) {
        let bytes = encode_png(&rgba, width, height)?;
        return Ok(EncodedClipboardImage { bytes, width, height, extension: "png" });
    }

    let rgb = rgba_to_rgb(&rgba);
    let bytes = encode_jpeg(&rgb, width, height, jpeg_quality.clamp(1, 100))?;
    Ok(EncodedClipboardImage { bytes, width, height, extension: "jpg" })
}

fn constrained_dimensions(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    if width <= max_edge && height <= max_edge {
        return (width, height);
    }

    if width >= height {
        let resized_height = scaled_dimension(height, width, max_edge);
        (max_edge, resized_height)
    } else {
        let resized_width = scaled_dimension(width, height, max_edge);
        (resized_width, max_edge)
    }
}

fn scaled_dimension(size: u32, source_edge: u32, max_edge: u32) -> u32 {
    let numerator = u64::from(size) * u64::from(max_edge);
    let denominator = u64::from(source_edge).max(1);
    u32::try_from(((numerator + denominator / 2) / denominator).max(1)).unwrap_or(max_edge)
}

fn resized_rgba_pixels(img: &image::RgbaImage, width: u32, height: u32) -> anyhow::Result<Vec<u8>> {
    if img.width() == width && img.height() == height {
        return Ok(img.as_raw().clone());
    }

    let options = pixo::ResizeOptions::builder(img.width(), img.height())
        .dst(width, height)
        .color_type(pixo::ColorType::Rgba)
        .algorithm(pixo::ResizeAlgorithm::Lanczos3)
        .build();
    pixo::resize::resize(img.as_raw(), &options).context("failed to resize clipboard image")
}

fn has_transparency(rgba: &[u8]) -> bool {
    rgba.chunks_exact(4).any(|pixel| pixel[3] != 255)
}

fn rgba_to_rgb(rgba: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
    for pixel in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&pixel[..3]);
    }
    rgb
}

fn encode_png(rgba: &[u8], width: u32, height: u32) -> anyhow::Result<Vec<u8>> {
    let options = pixo::png::PngOptions::builder(width, height)
        .color_type(pixo::ColorType::Rgba)
        .preset(1)
        .build();
    pixo::png::encode(rgba, &options).context("failed to encode clipboard image as PNG")
}

fn encode_jpeg(rgb: &[u8], width: u32, height: u32, quality: u8) -> anyhow::Result<Vec<u8>> {
    let options = pixo::jpeg::JpegOptions::builder(width, height)
        .color_type(pixo::ColorType::Rgb)
        .quality(quality)
        .preset(1)
        .build();
    pixo::jpeg::encode(rgb, &options).context("failed to encode clipboard image as JPEG")
}

/// Attempts to read text from the system clipboard.
///
/// Returns `None` for any failure path — clipboard unavailable, no text
/// content, IO error. Used as the fallback when Ctrl+V finds no image.
pub fn capture_clipboard_text() -> Option<String> {
    arboard::Clipboard::new().ok()?.get_text().ok()
}

/// Rewrites every `[Image N]` token in `buffer` whose `N` corresponds to a
/// registered slot into the canonical `@[<absolute-path>]` attachment
/// syntax. Tokens whose index is out of range are left untouched, so a
/// user typing `[Image 99]` literally is not silently rewritten.
///
/// Called by the REPL at message-submit time, after reedline returns the
/// buffer but before the line is dispatched into the agent pipeline.
pub fn expand_image_chips(buffer: &str) -> String {
    let registry = REGISTRY.lock().expect("clipboard registry mutex poisoned");
    expand_with_registry(buffer, &registry)
}

/// Internal helper extracted so the chip-expansion logic is unit-testable
/// without touching the global registry state.
fn expand_with_registry(buffer: &str, registry: &[PathBuf]) -> String {
    let mut out = String::with_capacity(buffer.len());
    let bytes = buffer.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if let Some((replacement, consumed)) = try_chip(bytes, i, registry) {
            out.push_str(&replacement);
            i += consumed;
        } else {
            // Safe: bytes[i] is a UTF-8 boundary because we only advance
            // by `consumed` on full chip matches (which are pure ASCII)
            // or by 1 when bytes[i] is a non-chip byte. For non-ASCII
            // text we copy the full multi-byte char rather than a single
            // byte to preserve UTF-8.
            let ch_start = i;
            let ch_len = utf8_char_len(bytes[i]);
            let ch_end = (ch_start + ch_len).min(bytes.len());
            out.push_str(&buffer[ch_start..ch_end]);
            i = ch_end;
        }
    }
    out
}

/// Returns the length of a UTF-8 character starting at `lead_byte`.
fn utf8_char_len(lead_byte: u8) -> usize {
    if lead_byte < 0x80 {
        1
    } else if lead_byte < 0xc0 {
        // Continuation byte in the middle of a char — defensive default.
        1
    } else if lead_byte < 0xe0 {
        2
    } else if lead_byte < 0xf0 {
        3
    } else {
        4
    }
}

/// Tries to match a `[Image N]` token starting at `start`. Returns
/// `Some((replacement, consumed))` if the token is well-formed AND the
/// index is in range of `registry`. The token must be exactly
/// `[Image <digits>]` with a single space — a literal user typing
/// `[Image  1]` (two spaces) or `[image 1]` (lowercase) is left alone.
fn try_chip(bytes: &[u8], start: usize, registry: &[PathBuf]) -> Option<(String, usize)> {
    const PREFIX: &[u8] = b"[Image ";
    if bytes.get(start..start + PREFIX.len())? != PREFIX {
        return None;
    }
    let mut cursor = start + PREFIX.len();
    let digits_start = cursor;
    while bytes
        .get(cursor)
        .copied()
        .map(|b| b.is_ascii_digit())
        .unwrap_or(false)
    {
        cursor += 1;
    }
    if cursor == digits_start {
        return None;
    }
    if bytes.get(cursor)? != &b']' {
        return None;
    }
    let n: usize = std::str::from_utf8(&bytes[digits_start..cursor])
        .ok()?
        .parse()
        .ok()?;
    if n == 0 {
        return None;
    }
    let path = registry.get(n - 1)?;
    let replacement = format!("@[{}]", path.display());
    Some((replacement, cursor + 1 - start))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use pretty_assertions::assert_eq;

    use super::*;

    fn fixture_registry() -> Vec<PathBuf> {
        vec![
            PathBuf::from("/Users/u/forge/clipboard/aaaaaaa1.png"),
            PathBuf::from("/Users/u/forge/clipboard/bbbbbbb2.png"),
        ]
    }

    fn fixture_opaque_image(width: u32, height: u32) -> image::RgbaImage {
        image::RgbaImage::from_fn(width, height, |x, y| {
            image::Rgba([
                ((x * 31 + y * 17) % 256) as u8,
                ((x * 11 + y * 29) % 256) as u8,
                ((x * 23 + y * 7) % 256) as u8,
                255,
            ])
        })
    }

    fn fixture_transparent_image(width: u32, height: u32) -> image::RgbaImage {
        image::RgbaImage::from_fn(width, height, |x, y| {
            let alpha = if x == y { 128 } else { 255 };
            image::Rgba([64, 128, 192, alpha])
        })
    }

    #[test]
    fn test_capture_returns_ok_none_when_clipboard_empty() {
        // We cannot control the system clipboard in unit tests; this just
        // confirms the function returns Ok rather than panicking when
        // arboard is unavailable (e.g. CI).
        let actual = capture_clipboard_image();
        let expected_is_err = false;
        assert_eq!(actual.is_err(), expected_is_err);
    }

    #[test]
    fn test_encode_clipboard_image_downscales_and_encodes_jpeg() {
        let fixture = fixture_opaque_image(8, 4);
        let encoded = encode_clipboard_image_with_limits(&fixture, 4, 82).unwrap();
        let actual = (
            encoded.width,
            encoded.height,
            encoded.extension,
            encoded.bytes.starts_with(&[0xff, 0xd8]),
            encoded.bytes.ends_with(&[0xff, 0xd9]),
            encoded.bytes.is_empty(),
        );
        let expected = (4, 2, "jpg", true, true, false);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_encode_clipboard_image_preserves_transparent_png() {
        let fixture = fixture_transparent_image(4, 4);
        let encoded = encode_clipboard_image_with_limits(&fixture, 8, 82).unwrap();
        let actual = (
            encoded.width,
            encoded.height,
            encoded.extension,
            encoded
                .bytes
                .starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]),
            encoded.bytes.is_empty(),
        );
        let expected = (4, 4, "png", true, false);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_constrained_dimensions_preserves_aspect_ratio() {
        let fixture = (1600, 600);
        let actual = (
            constrained_dimensions(3200, 1600, fixture.0),
            constrained_dimensions(900, 1800, fixture.1),
        );
        let expected = ((1600, 800), (300, 600));
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_single_chip() {
        let registry = fixture_registry();
        let actual = expand_with_registry("[Image 1] what is this", &registry);
        let expected = "@[/Users/u/forge/clipboard/aaaaaaa1.png] what is this";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_multiple_chips() {
        let registry = fixture_registry();
        let actual = expand_with_registry("compare [Image 1] and [Image 2]", &registry);
        let expected = "compare @[/Users/u/forge/clipboard/aaaaaaa1.png] and @[/Users/u/forge/clipboard/bbbbbbb2.png]";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_leaves_out_of_range_chips_alone() {
        let registry = fixture_registry();
        let actual = expand_with_registry("see [Image 99] please", &registry);
        let expected = "see [Image 99] please";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_leaves_zero_alone() {
        let registry = fixture_registry();
        let actual = expand_with_registry("[Image 0] is bad", &registry);
        let expected = "[Image 0] is bad";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_leaves_lowercase_alone() {
        let registry = fixture_registry();
        let actual = expand_with_registry("[image 1] no", &registry);
        let expected = "[image 1] no";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_leaves_extra_space_alone() {
        let registry = fixture_registry();
        let actual = expand_with_registry("[Image  1] no", &registry);
        let expected = "[Image  1] no";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_preserves_unicode() {
        let registry = fixture_registry();
        let actual = expand_with_registry("こんにちは [Image 1] 世界", &registry);
        let expected = "こんにちは @[/Users/u/forge/clipboard/aaaaaaa1.png] 世界";
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_expand_no_registry_no_match() {
        let registry: Vec<PathBuf> = vec![];
        let actual = expand_with_registry("[Image 1] hi", &registry);
        let expected = "[Image 1] hi";
        assert_eq!(actual, expected);
    }
}

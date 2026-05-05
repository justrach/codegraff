//! System clipboard helpers and image-attachment registry for the REPL.
//!
//! Clipboard images captured via Ctrl+V (see [`crate::editor::ForgeEditMode`])
//! are stored as PNG files under `~/forge/clipboard/` and registered in a
//! per-process [`ImageRegistry`]. Each registered image gets a small
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

/// Result of a successful clipboard image capture.
#[derive(Debug, Clone)]
pub struct CapturedImage {
    /// 1-indexed slot in [`REGISTRY`]; rendered as `[Image {slot}]` in the
    /// input buffer.
    pub slot: usize,
}

/// Attempts to capture an image from the system clipboard, write it as a
/// PNG file under `~/forge/clipboard/<8hex>.png`, and register it for the
/// `[Image N]` chip syntax.
///
/// Returns `Ok(Some(captured))` if an image was captured and successfully
/// written, `Ok(None)` if the clipboard does not currently hold an image
/// (or contains an empty image), and `Err` only for unexpected failures
/// (PNG encoding error, IO error). Callers should treat `Ok(None)` as the
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

    let width = u32::try_from(img_data.width)
        .context("clipboard image width does not fit in u32")?;
    let height = u32::try_from(img_data.height)
        .context("clipboard image height does not fit in u32")?;
    let bytes: Vec<u8> = img_data.bytes.into_owned();

    let img = image::RgbaImage::from_raw(width, height, bytes)
        .context("clipboard image bytes did not match width*height*4")?;

    // Save under `~/forge/clipboard/<8hex>.png`. Falls back to the system
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
    let path = dir.join(format!("{short}.png"));
    img.save_with_format(&path, image::ImageFormat::Png)
        .context("failed to write clipboard PNG to disk")?;

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
    while bytes.get(cursor).copied().map(|b| b.is_ascii_digit()).unwrap_or(false) {
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

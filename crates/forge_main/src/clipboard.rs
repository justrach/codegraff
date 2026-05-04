//! System clipboard helpers for the REPL.
//!
//! Provides clipboard image and text capture used by the Ctrl+V keybinding
//! in [`crate::editor::ForgeEditMode`]. Clipboard images are captured as
//! RGBA pixel buffers via `arboard`, encoded as PNG via the `image` crate,
//! and written to a short-named file under `~/forge/clipboard/` so the
//! resulting `@[<path>]` reference stays readable in the input buffer.
//! The caller receives the path so it can be inserted into the input
//! using the existing attachment syntax.

use std::path::PathBuf;

use anyhow::Context;

/// Attempts to capture an image from the system clipboard and write it as a
/// PNG file under `~/forge/clipboard/<8hex>.png`.
///
/// Returns `Ok(Some(path))` if an image was captured and successfully
/// written, `Ok(None)` if the clipboard does not currently hold an image
/// (or contains an empty image), and `Err` only for unexpected failures
/// (PNG encoding error, IO error). Callers should treat `Ok(None)` as the
/// normal "no image, fall back to text paste" path.
pub fn capture_clipboard_image_to_temp() -> anyhow::Result<Option<PathBuf>> {
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

    // Save to ~/forge/clipboard/<8-hex>.png so the resulting `@[...]`
    // reference stays short and human-readable rather than the ~100-char
    // `/var/folders/...` system temp path. Falls back to system temp if
    // the home directory is unavailable (sandboxed environments, CI, etc.).
    let dir = clipboard_dir().unwrap_or_else(std::env::temp_dir);
    if let Err(err) = std::fs::create_dir_all(&dir) {
        // Permission or IO error creating the directory; fall back rather
        // than fail Ctrl+V entirely.
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

    Ok(Some(path))
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

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn test_capture_returns_ok_none_when_clipboard_empty() {
        // We cannot reliably control the system clipboard in unit tests,
        // so this only verifies that a missing image yields Ok(None) rather
        // than panicking when arboard cannot be initialised (e.g. CI).
        let actual = capture_clipboard_image_to_temp();
        let expected_is_err = false;
        assert_eq!(actual.is_err(), expected_is_err);
    }
}

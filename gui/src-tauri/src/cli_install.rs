//! First-run install of the bundled `codegraff` CLI onto the user's PATH.
//!
//! The app bundles the Zig-native harness binary at
//! `Codegraff.app/Contents/Resources/codegraff`. On macOS we expose it as a
//! `codegraff` terminal command by symlinking it into a PATH directory the
//! first time the app launches (VS Code `code`-style).
//!
//! Best-effort by design: it never fails app startup. In dev the bundled
//! resource does not exist, so this is a natural no-op. When `/usr/local/bin`
//! is not writable (common on stock macOS without Homebrew) it falls back to
//! `~/.local/bin`.

#[cfg(target_os = "macos")]
pub fn ensure_cli_symlink(app: &tauri::App) {
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use tauri::Manager;

    let resource = match app.path().resource_dir() {
        Ok(dir) => dir.join("codegraff"),
        Err(_) => return,
    };
    // Only present in a bundled .app — absent in dev, so this returns quietly.
    if !resource.exists() {
        return;
    }

    // Preferred PATH dirs, in order. /usr/local/bin matches the VS Code `code`
    // convention; ~/.local/bin is the no-admin fallback.
    let mut targets: Vec<PathBuf> = vec![PathBuf::from("/usr/local/bin")];
    if let Ok(home) = app.path().home_dir() {
        targets.push(home.join(".local").join("bin"));
    }

    for dir in targets {
        let link = dir.join("codegraff");
        // Already linked to this exact build -> nothing to do.
        if let Ok(existing) = std::fs::read_link(&link) {
            if existing == resource {
                log::info!("codegraff CLI already linked at {}", link.display());
                return;
            }
        }
        if std::fs::create_dir_all(&dir).is_err() {
            continue;
        }
        // Clear any stale link/file we own before relinking.
        let _ = std::fs::remove_file(&link);
        match symlink(&resource, &link) {
            Ok(()) => {
                log::info!(
                    "codegraff CLI linked: {} -> {}",
                    link.display(),
                    resource.display()
                );
                return;
            }
            Err(err) => {
                log::warn!("could not link codegraff into {}: {err}", dir.display());
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn ensure_cli_symlink(_app: &tauri::App) {}

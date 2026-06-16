use std::env;
use std::fs::metadata;
use std::path::Path;
use std::process::Command;

use anyhow::Context;
use bstr::ByteSlice;

const OPEN_TARGET_IDS: &[&str] = &[
    "cursor",
    "zed",
    "file-manager",
    "terminal",
    "ghostty",
    "warp",
    "xcode",
    "android-studio",
];

pub fn detect_available_open_targets() -> Vec<String> {
    OPEN_TARGET_IDS
        .iter()
        .copied()
        .filter(|target_id| is_open_target_available(target_id))
        .map(str::to_string)
        .collect()
}

// Copied "open in a specific IDE/app" path; not wired by the simple adapter
// yet (it uses open_path_default / open_path_for_edit). Kept for future parity.
#[allow(dead_code)]
pub fn open_path_in_target(target_id: &str, path: &Path) -> anyhow::Result<()> {
    let mut command = build_open_command(target_id, path)
        .with_context(|| format!("Unsupported open target: {target_id}"))?;

    let output = command.output().with_context(|| {
        format!("Failed to launch {target_id}. Make sure the target app is installed.")
    })?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    let stdout = output.stdout.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }
    if !stdout.is_empty() {
        anyhow::bail!("{stdout}");
    }

    anyhow::bail!("Failed to launch {target_id}.")
}

pub fn open_external_url(url: &str) -> anyhow::Result<()> {
    let mut command = build_open_url_command(url);
    let output = command
        .output()
        .with_context(|| "Failed to open the external URL.".to_string())?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    let stdout = output.stdout.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }
    if !stdout.is_empty() {
        anyhow::bail!("{stdout}");
    }

    anyhow::bail!("Failed to open the external URL.")
}

pub fn open_path_default(path: &Path) -> anyhow::Result<()> {
    let mut command = build_open_path_command(path);
    let output = command
        .output()
        .with_context(|| "Failed to open the file with the default app.".to_string())?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    let stdout = output.stdout.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }
    if !stdout.is_empty() {
        anyhow::bail!("{stdout}");
    }

    anyhow::bail!("Failed to open the file with the default app.")
}

fn is_open_target_available(target_id: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        mac_app_name(target_id)
            .map(is_mac_app_available)
            .unwrap_or_else(|| target_id == "file-manager" && command_exists("open"))
    }

    #[cfg(target_os = "windows")]
    {
        command_candidates(target_id)
            .iter()
            .copied()
            .any(command_exists)
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        command_candidates(target_id)
            .iter()
            .copied()
            .any(command_exists)
    }
}

#[allow(dead_code)]
fn build_open_command(target_id: &str, path: &Path) -> Option<Command> {
    #[cfg(target_os = "macos")]
    {
        let mut command = Command::new("open");
        if let Some(app_name) = mac_app_name(target_id) {
            command.arg("-a").arg(app_name);
        } else if target_id != "file-manager" {
            return None;
        }
        command.arg(path);
        Some(command)
    }

    #[cfg(target_os = "windows")]
    {
        let mut command = Command::new(resolve_command(target_id)?);
        command.arg(path);
        Some(command)
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let mut command = Command::new(resolve_command(target_id)?);
        command.arg(path);
        Some(command)
    }
}

fn build_open_url_command(url: &str) -> Command {
    #[cfg(target_os = "macos")]
    {
        let mut command = Command::new("open");
        command.arg(url);
        command
    }

    #[cfg(target_os = "windows")]
    {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", "", url]);
        command
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let mut command = Command::new("xdg-open");
        command.arg(url);
        command
    }
}

/// Opens a path in the default text editor (for editing config files that may
/// have no GUI file-type association, like `~/.zshrc`).
pub fn open_path_for_edit(path: &Path) -> anyhow::Result<()> {
    let mut command = build_open_edit_command(path);
    let output = command
        .output()
        .with_context(|| "Failed to open the file for editing.".to_string())?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = output.stderr.as_bstr().trim().to_str_lossy().into_owned();
    if !stderr.is_empty() {
        anyhow::bail!("{stderr}");
    }
    anyhow::bail!("Failed to open the file for editing.")
}

fn build_open_edit_command(path: &Path) -> Command {
    #[cfg(target_os = "macos")]
    {
        // `-t` opens with the default text editor rather than the (possibly
        // unset) default app for an extensionless dotfile.
        let mut command = Command::new("open");
        command.arg("-t").arg(path);
        command
    }

    #[cfg(target_os = "windows")]
    {
        let mut command = Command::new("notepad");
        command.arg(path);
        command
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let mut command = Command::new("xdg-open");
        command.arg(path);
        command
    }
}

fn build_open_path_command(path: &Path) -> Command {
    #[cfg(target_os = "macos")]
    {
        let mut command = Command::new("open");
        command.arg(path);
        command
    }

    #[cfg(target_os = "windows")]
    {
        let mut command = Command::new("cmd");
        command.arg("/C").arg("start").arg("").arg(path);
        command
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let mut command = Command::new("xdg-open");
        command.arg(path);
        command
    }
}

#[cfg(target_os = "macos")]
fn mac_app_name(target_id: &str) -> Option<&'static str> {
    match target_id {
        "cursor" => Some("Cursor"),
        "zed" => Some("Zed"),
        "terminal" => Some("Terminal"),
        "ghostty" => Some("Ghostty"),
        "warp" => Some("Warp"),
        "xcode" => Some("Xcode"),
        "android-studio" => Some("Android Studio"),
        "file-manager" => None,
        _ => None,
    }
}

#[cfg(target_os = "windows")]
fn command_candidates(target_id: &str) -> &'static [&'static str] {
    match target_id {
        "cursor" => &["cursor"],
        "zed" => &["zed"],
        "file-manager" => &["explorer"],
        "ghostty" => &["ghostty"],
        "warp" => &["warp"],
        "android-studio" => &["studio"],
        _ => &[],
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn command_candidates(target_id: &str) -> &'static [&'static str] {
    match target_id {
        "cursor" => &["cursor"],
        "zed" => &["zed"],
        "file-manager" => &["xdg-open"],
        "terminal" => &["x-terminal-emulator", "gnome-terminal"],
        "ghostty" => &["ghostty"],
        "warp" => &["warp"],
        "android-studio" => &["studio"],
        _ => &[],
    }
}

#[cfg(not(target_os = "macos"))]
fn resolve_command(target_id: &str) -> Option<&'static str> {
    command_candidates(target_id)
        .iter()
        .copied()
        .find(|command| command_exists(command))
        .or_else(|| command_candidates(target_id).first().copied())
}

#[cfg(target_os = "macos")]
fn is_mac_app_available(app_name: &str) -> bool {
    Command::new("open")
        .args(["-Ra", app_name])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn command_exists(command: &str) -> bool {
    let path_value = env::var_os("PATH").unwrap_or_default();
    env::split_paths(&path_value).any(|directory| {
        let candidate = directory.join(command);
        is_executable_file(&candidate)
    })
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(file_metadata) = metadata(path) else {
        return false;
    };

    if !file_metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        file_metadata.permissions().mode() & 0o111 != 0
    }

    #[cfg(windows)]
    {
        true
    }
}

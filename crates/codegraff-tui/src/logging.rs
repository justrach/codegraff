use std::fs::OpenOptions;
use std::io::Write;
use std::panic;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const CODEGRAFF_LOG_FILE: &str = "codegraff.log";

/// Returns the debug log path for the CodeGraff TUI.
pub(crate) fn codegraff_log_path() -> PathBuf {
    codegraff_log_path_from(
        std::env::var_os("CODEGRAFF_LOG")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from),
        std::env::var_os("XDG_STATE_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from),
        std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from),
    )
}

/// Builds the debug log path from explicit environment-derived locations.
pub(crate) fn codegraff_log_path_from(
    override_path: Option<PathBuf>,
    state_home: Option<PathBuf>,
    home: Option<PathBuf>,
) -> PathBuf {
    override_path.unwrap_or_else(|| {
        state_home
            .or_else(|| home.map(|home| home.join(".local/state")))
            .unwrap_or_else(|| PathBuf::from("."))
            .join("codegraff")
            .join(CODEGRAFF_LOG_FILE)
    })
}

/// Installs a panic hook that mirrors panic details into the debug log.
pub(crate) fn install_panic_logger(log_path: PathBuf) {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        append_log_line(&log_path, &format!("PANIC {info}"));
        previous_hook(info);
    }));
}

/// Writes an informational message to the debug log.
pub(crate) fn log_info(path: &Path, message: &str) {
    append_log_line(path, &format!("INFO {message}"));
}

/// Writes an error message with context to the debug log.
pub(crate) fn log_error(path: &Path, context: &str, error: &anyhow::Error) {
    append_log_line(path, &format!("ERROR {context}: {error:#}"));
}

/// Appends a timestamped line to the debug log file.
pub(crate) fn append_log_line(path: &Path, line: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_else(|_| "0".to_string());

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{timestamp} {line}");
    }
}

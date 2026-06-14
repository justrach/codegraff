use std::fs;
use std::path::{Path, PathBuf};

const APP_FORGE_DIR_NAME: &str = "forge";
const IMPORT_MARKER_FILE: &str = ".codegraff-gui-imported-global-forge";
const IMPORT_FILES: &[&str] = &[
    ".forge.toml",
    ".config.json",
    ".credentials.json",
    "provider.json",
    ".forge.db",
    ".forge_history",
    "AGENTS.md",
];
const IMPORT_DIRS: &[&str] = &["commands", "skills"];

pub(crate) fn initialize_app_forge_config(
    app_dir: &Path,
    home_dir: Option<&Path>,
) -> anyhow::Result<PathBuf> {
    let app_forge_dir = app_dir.join(APP_FORGE_DIR_NAME);
    fs::create_dir_all(&app_forge_dir)?;

    import_global_forge_config_once(&app_forge_dir, home_dir)?;

    // Forge crates resolve config, provider credentials, and provider.json from
    // FORGE_CONFIG, so set it before any runtime config read happens.
    unsafe {
        std::env::set_var("FORGE_CONFIG", &app_forge_dir);
    }

    Ok(app_forge_dir)
}

fn import_global_forge_config_once(
    app_forge_dir: &Path,
    home_dir: Option<&Path>,
) -> anyhow::Result<()> {
    let marker_path = app_forge_dir.join(IMPORT_MARKER_FILE);
    if marker_path.exists() {
        return Ok(());
    }

    let marker_contents = if is_app_forge_dir_uninitialized(app_forge_dir)? {
        if let Some(source) = find_global_forge_dir(app_forge_dir, home_dir) {
            match copy_forge_config(&source, app_forge_dir) {
                Ok(()) => format!("imported_from={}\n", source.display()),
                Err(error) => {
                    log::warn!(
                        "Failed to import global Forge config from {}: {error:#}",
                        source.display()
                    );
                    format!(
                        "imported_from={}\nimport_error={error:#}\n",
                        source.display()
                    )
                }
            }
        } else {
            "imported_from=\n".to_string()
        }
    } else {
        "imported_from=\nexisting_app_config=true\n".to_string()
    };
    fs::write(marker_path, marker_contents)?;

    Ok(())
}

fn is_app_forge_dir_uninitialized(app_forge_dir: &Path) -> anyhow::Result<bool> {
    for entry in fs::read_dir(app_forge_dir)? {
        let entry = entry?;
        if entry.file_name() != IMPORT_MARKER_FILE {
            return Ok(false);
        }
    }

    Ok(true)
}

fn find_global_forge_dir(app_forge_dir: &Path, home_dir: Option<&Path>) -> Option<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(path) = std::env::var_os("FORGE_CONFIG").map(PathBuf::from) {
        candidates.push(path);
    }

    if let Some(home_dir) = home_dir {
        candidates.push(home_dir.join("forge"));
        candidates.push(home_dir.join(".forge"));
    }

    candidates
        .into_iter()
        .find(|path| path.is_dir() && !same_directory(path, app_forge_dir))
}

fn same_directory(left: &Path, right: &Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

fn copy_forge_config(source_dir: &Path, app_forge_dir: &Path) -> anyhow::Result<()> {
    for file_name in IMPORT_FILES {
        copy_file_if_present(&source_dir.join(file_name), &app_forge_dir.join(file_name))?;
    }

    for dir_name in IMPORT_DIRS {
        copy_dir_if_present(&source_dir.join(dir_name), &app_forge_dir.join(dir_name))?;
    }

    Ok(())
}

fn copy_file_if_present(source: &Path, destination: &Path) -> anyhow::Result<()> {
    if !source.is_file() || destination.exists() {
        return Ok(());
    }

    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, destination)?;

    Ok(())
}

fn copy_dir_if_present(source: &Path, destination: &Path) -> anyhow::Result<()> {
    if !source.is_dir() || destination.exists() {
        return Ok(());
    }

    copy_dir_recursive(source, destination)
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(destination)?;

    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());

        if file_type.is_dir() {
            copy_dir_recursive(&source_path, &destination_path)?;
        } else if file_type.is_file() {
            fs::copy(&source_path, &destination_path)?;
        }
    }

    Ok(())
}

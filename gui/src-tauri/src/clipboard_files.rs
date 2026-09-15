//! Clipboard exports carry ownership separately from paths supplied by users.
//! A process lease protects drafts; accepted prompts retain files for replay.
use std::{
    fs::{self, File, OpenOptions, ReadDir},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

static STORE: OnceLock<Mutex<Option<Store>>> = OnceLock::new();

fn with_store<T>(operation: impl FnOnce(&mut Store) -> io::Result<T>) -> io::Result<T> {
    let mut slot = STORE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| io::Error::other("clipboard ownership lock poisoned"))?;
    if slot.is_none() {
        *slot = Some(Store::new(std::env::temp_dir().join("codegraff-pasted"))?);
    }
    operation(slot.as_mut().expect("initialized clipboard store"))
}

pub(crate) fn save(data: &[u8], ext: &str) -> io::Result<String> {
    with_store(|store| {
        // Recovery is best effort; an unreadable old record must not block paste.
        let _ = store.sweep(64);
        store
            .save(data, ext)
            .map(|path| path.to_string_lossy().into_owned())
    })
}

pub(crate) fn discard(path: &str) -> io::Result<()> {
    with_existing(|store| store.discard(Path::new(path)))
}

pub(crate) fn retain_prompt(prompt: &str) -> io::Result<()> {
    if !prompt.contains("@[") {
        return Ok(());
    }
    with_existing(|store| store.retain_prompt(prompt))
}

fn with_existing(operation: impl FnOnce(&Store) -> io::Result<()>) -> io::Result<()> {
    let Some(lock) = STORE.get() else {
        return Ok(());
    };
    let slot = lock
        .lock()
        .map_err(|_| io::Error::other("clipboard ownership lock poisoned"))?;
    match slot.as_ref() {
        Some(store) => operation(store),
        None => Ok(()),
    }
}

pub(crate) fn cleanup() {
    // Do not initialize a store just to shut down. Sent files remain replayable.
    if let Some(lock) = STORE.get() {
        if let Ok(mut slot) = lock.lock() {
            if let Some(store) = slot.as_mut() {
                let _ = store.cleanup();
            }
        }
    }
}

struct Store {
    root: PathBuf,
    owner: PathBuf,
    _lease: File,
    owners: Option<ReadDir>,
    records: Option<(PathBuf, ReadDir)>,
}

fn private_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).read(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn identity(path: &Path) -> io::Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() {
        return Err(io::Error::other("not a regular clipboard file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(format!("{}:{}", metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        // Without a durable file identity, leave cleanup to the OS rather than
        // treat a reused path as authority to delete a replacement file.
        Ok(String::new())
    }
}

fn record_path(path: &Path) -> PathBuf {
    path.with_extension(format!(
        "{}.owned",
        path.extension().unwrap_or_default().to_string_lossy()
    ))
}

fn record(path: &Path) -> io::Result<Option<(bool, String)>> {
    let record = record_path(path);
    let Ok(metadata) = fs::symlink_metadata(&record) else {
        return Ok(None);
    };
    if !metadata.is_file() || metadata.len() > 256 {
        return Ok(None);
    }
    let content = fs::read_to_string(record)?;
    let Some((state, saved_identity)) = content.split_once('\n') else {
        return Ok(None);
    };
    if !matches!(state, "pending" | "retained") {
        return Ok(None);
    }
    let Ok(current_identity) = identity(path) else {
        return Ok(None);
    };
    if saved_identity.is_empty() || saved_identity != current_identity {
        return Ok(None);
    }
    Ok(Some((state == "retained", current_identity)))
}

impl Store {
    fn new(root: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&root)?;
        let owner = root.join(format!("owner-{}", uuid::Uuid::new_v4().simple()));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&owner)?;
        let lease = private_file(&owner.join("lease"))?;
        lease.lock()?;
        Ok(Self {
            root,
            owner,
            _lease: lease,
            owners: None,
            records: None,
        })
    }

    fn save(&self, bytes: &[u8], ext: &str) -> io::Result<PathBuf> {
        let ext = ext.to_ascii_lowercase();
        let ext = match ext.as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "avif" => ext.as_str(),
            _ => "png",
        };
        let path = self
            .owner
            .join(format!("{}.{}", uuid::Uuid::new_v4().simple(), ext));
        let mut file = private_file(&path)?;
        let file_identity = identity(&path)?;
        let mut record_created = false;
        let result = (|| {
            file.write_all(bytes)?;
            file.sync_all()?;
            let mut metadata = private_file(&record_path(&path))?;
            record_created = true;
            metadata.write_all(format!("pending\n{file_identity}").as_bytes())?;
            metadata.sync_all()
        })();
        if let Err(error) = result {
            // Never remove a pre-existing record or a replaced export on error.
            drop(file);
            if identity(&path).is_ok_and(|current| current == file_identity) {
                let _ = fs::remove_file(&path);
            }
            if record_created {
                let _ = fs::remove_file(record_path(&path));
            }
            return Err(error);
        }
        Ok(path)
    }

    fn discard(&self, path: &Path) -> io::Result<()> {
        if path.parent() != Some(self.owner.as_path()) {
            return Ok(());
        }
        Self::discard_recorded(path)
    }

    fn discard_recorded(path: &Path) -> io::Result<()> {
        if matches!(record(path)?, Some((false, _))) {
            fs::remove_file(path)?;
            fs::remove_file(record_path(path))?;
        }
        Ok(())
    }

    fn retain_prompt(&self, prompt: &str) -> io::Result<()> {
        for marker in prompt.split("@[").skip(1) {
            let Some((name, _)) = marker.split_once(']') else {
                continue;
            };
            let path = Path::new(name);
            if path.parent() != Some(self.owner.as_path()) {
                continue;
            }
            let Some((false, identity)) = record(path)? else {
                continue;
            };
            let temporary = self
                .owner
                .join(format!("{}.pending", uuid::Uuid::new_v4().simple()));
            let result = (|| {
                let mut file = private_file(&temporary)?;
                file.write_all(format!("retained\n{identity}").as_bytes())?;
                file.sync_all()?;
                fs::rename(&temporary, record_path(path))
            })();
            if result.is_err() {
                let _ = fs::remove_file(temporary);
            }
            result?;
        }
        Ok(())
    }

    fn cleanup(&self) -> io::Result<()> {
        for entry in fs::read_dir(&self.owner)? {
            let path = entry?.path();
            if path.extension().is_some_and(|ext| ext == "owned") {
                Self::discard_recorded(&path.with_extension(""))?;
            }
        }
        Ok(())
    }

    /// Count every directory entry, including retained records, against the
    /// budget. Keep cursors so an old retained entry cannot starve later files.
    fn sweep(&mut self, budget: usize) -> io::Result<()> {
        if self.owners.is_none() {
            self.owners = Some(fs::read_dir(&self.root)?);
        }
        for _ in 0..budget {
            if let Some((owner, entries)) = self.records.as_mut() {
                // A successful exclusive lock is evidence the old owner exited.
                // Never wait on a live GUI, nor keep recovery locks between calls.
                let lease_path = owner.join("lease");
                if !fs::symlink_metadata(&lease_path).is_ok_and(|m| m.is_file()) {
                    self.records = None;
                    continue;
                }
                let Ok(lease) = OpenOptions::new().read(true).write(true).open(lease_path) else {
                    self.records = None;
                    continue;
                };
                if lease.try_lock().is_err() {
                    self.records = None;
                    continue;
                }
                if let Some(entry) = entries.next() {
                    let path = entry?.path();
                    if path.extension().is_some_and(|ext| ext == "owned") {
                        Self::discard_recorded(&path.with_extension(""))?;
                    }
                } else {
                    self.records = None;
                }
            } else if let Some(entry) = self.owners.as_mut().and_then(Iterator::next) {
                let entry = entry?;
                if entry.path() != self.owner
                    && entry.file_type()?.is_dir()
                    && entry.file_name().to_string_lossy().starts_with("owner-")
                {
                    self.records = Some((entry.path(), fs::read_dir(entry.path())?));
                }
            } else {
                self.owners = None;
                break;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "clipboard_files_tests.rs"]
mod tests;

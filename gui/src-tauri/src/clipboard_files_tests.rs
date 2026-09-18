use super::*;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("clipboard-test-{}", uuid::Uuid::new_v4())))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
#[cfg(unix)]
fn removing_a_draft_deletes_only_its_owned_export() {
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let original = fixture.0.join("original.png");
    fs::write(&original, b"original").unwrap();
    let pasted = store.save(b"pasted pixels", "PNG").unwrap();
    store.discard(&original).unwrap();
    store.discard(&pasted).unwrap();
    assert_eq!(fs::read(original).unwrap(), b"original");
    assert!(!pasted.exists());
    assert!(!record_path(&pasted).exists());
}

#[test]
#[cfg(unix)]
fn accepted_prompt_survives_remove_shutdown_and_owner_recovery() {
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let sent = store.save(b"sent pixels", "png").unwrap();
    let pending = store.save(b"draft pixels", "png").unwrap();
    store
        .retain_prompt(&format!("Inspect\nAttached files:\n@[{}]", sent.display()))
        .unwrap();
    store.discard(&sent).unwrap();
    store.cleanup().unwrap();
    assert!(!pending.exists());
    drop(store);
    let mut recovery = Store::new(fixture.0.clone()).unwrap();
    recovery.sweep(100).unwrap();
    assert_eq!(fs::read(sent).unwrap(), b"sent pixels");
}

#[test]
#[cfg(unix)]
fn active_owner_lock_protects_drafts_until_owner_exits() {
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let draft = store.save(b"draft", "png").unwrap();
    let mut other = Store::new(fixture.0.clone()).unwrap();
    other.sweep(100).unwrap();
    assert!(draft.exists());
    drop(store);
    for _ in 0..100 {
        other.sweep(1).unwrap();
    }
    assert!(!draft.exists());
}

#[test]
#[cfg(unix)]
fn replacement_and_unrecorded_files_never_grant_deletion_authority() {
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let draft = store.save(b"draft", "png").unwrap();
    // Keep the first inode alive so the replacement cannot reuse its identity.
    let original = File::open(&draft).unwrap();
    fs::remove_file(&draft).unwrap();
    fs::write(&draft, b"replacement").unwrap();
    let unknown = store.owner.join("unknown.png");
    fs::write(&unknown, b"unknown").unwrap();
    store.discard(&draft).unwrap();
    store.discard(&unknown).unwrap();
    drop(store);
    let mut other = Store::new(fixture.0.clone()).unwrap();
    other.sweep(100).unwrap();
    assert_eq!(fs::read(draft).unwrap(), b"replacement");
    assert!(unknown.exists());
    drop(original);
}

#[test]
#[cfg(unix)]
fn bounded_recovery_eventually_visits_every_pending_record() {
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let mut paths = Vec::new();
    for _ in 0..20 {
        paths.push(store.save(b"draft", "png").unwrap());
    }
    drop(store);
    let mut other = Store::new(fixture.0.clone()).unwrap();
    other.sweep(2).unwrap();
    assert!(paths.iter().filter(|path| !path.exists()).count() <= 2);
    for _ in 0..100 {
        other.sweep(2).unwrap();
    }
    assert!(paths.iter().all(|path| !path.exists()));
}

#[test]
#[cfg(unix)]
fn symlinked_image_and_record_are_preserved() {
    use std::os::unix::fs::symlink;
    let fixture = Fixture::new();
    let store = Store::new(fixture.0.clone()).unwrap();
    let pasted = store.save(b"pixels", "png").unwrap();
    let original = fixture.0.join("original");
    fs::write(&original, b"original").unwrap();
    fs::remove_file(&pasted).unwrap();
    symlink(&original, &pasted).unwrap();
    store.discard(&pasted).unwrap();
    assert!(fs::symlink_metadata(&pasted).unwrap().is_symlink());
    assert_eq!(fs::read(&original).unwrap(), b"original");
    let other = store.save(b"other", "png").unwrap();
    let metadata = record_path(&other);
    let moved = store.owner.join("saved-record");
    fs::rename(&metadata, &moved).unwrap();
    symlink(moved, &metadata).unwrap();
    store.discard(&other).unwrap();
    assert!(other.exists());
}

// Run only as the child of the recovery test. It owns a genuine OS lease and
// leaves its files behind on exit, as a stopped/crashed GUI would.
#[test]
#[ignore]
fn owner_process_fixture() {
    use std::io::Read;
    let root = PathBuf::from(std::env::var_os("GRAFF_CLIPBOARD_TEST_ROOT").unwrap());
    let store = Store::new(root.clone()).unwrap();
    let draft = store.save(b"pending child pixels", "png").unwrap();
    let sent = store.save(b"sent child pixels", "png").unwrap();
    store
        .retain_prompt(&format!("@[{}]", sent.display()))
        .unwrap();
    fs::write(
        root.join("ready.pending"),
        format!("{}\n{}", draft.display(), sent.display()),
    )
    .unwrap();
    fs::rename(root.join("ready.pending"), root.join("ready")).unwrap();
    let _ = std::io::stdin().read_to_end(&mut Vec::new());
    drop(store);
}

#[test]
#[cfg(unix)]
fn recovery_observes_a_real_owner_process_exiting() {
    use std::{
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };
    let fixture = Fixture::new();
    let mut recovery = Store::new(fixture.0.clone()).unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "clipboard_files::tests::owner_process_fixture",
            "--ignored",
        ])
        .env("GRAFF_CLIPBOARD_TEST_ROOT", &fixture.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !fixture.0.join("ready").exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if !fixture.0.join("ready").exists() {
        let _ = child.kill();
        let status = child.wait();
        panic!("clipboard owner did not initialize: {status:?}");
    }
    let paths = fs::read_to_string(fixture.0.join("ready")).unwrap();
    let (draft, sent) = paths.split_once('\n').unwrap();
    recovery.sweep(100).unwrap();
    let live_draft_exists = Path::new(draft).exists();
    drop(child.stdin.take()); // Only this fixture's process is asked to exit.
    assert!(child.wait().unwrap().success());
    assert!(live_draft_exists, "recovery removed a live process's draft");
    recovery.sweep(100).unwrap();
    assert!(!Path::new(draft).exists());
    assert_eq!(fs::read(sent).unwrap(), b"sent child pixels");
}

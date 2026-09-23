use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

pub(super) fn gh_merged_pr(repo: &Path, branch: &str) -> Option<bool> {
    let mut command = Command::new("gh");
    command
        .args([
            "pr",
            "list",
            "--head",
            branch,
            "--state",
            "merged",
            "--json",
            "number",
            "--limit",
            "1",
        ])
        .current_dir(repo)
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let text = run_timeout(&mut command, Duration::from_secs(3))?;
    if text.trim().is_empty() || text.trim() == "[]" {
        return Some(false);
    }
    Some(text.contains("\"number\""))
}

pub(super) fn run_timeout(command: &mut Command, timeout: Duration) -> Option<String> {
    let mut child = command.spawn().ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let mut text = String::new();
                if let Some(mut stdout) = child.stdout.take() {
                    let _ = stdout.read_to_string(&mut text);
                }
                let _ = child.wait();
                return Some(text);
            }
            Ok(None) if started.elapsed() > timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => thread::sleep(Duration::from_millis(40)),
            Err(_) => return None,
        }
    }
}

pub(super) fn resolve_dir(path: &Path) -> Result<PathBuf> {
    fs::canonicalize(path).with_context(|| format!("workspace not found: {}", path.display()))
}

pub(super) fn git(cwd: &Path, args: &[&str]) -> Result<std::process::Output> {
    Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("failed to run git {}", args.join(" ")))
}

pub(super) fn git_stdout(cwd: &Path, args: &[&str]) -> Result<String> {
    let output = git(cwd, args)?;
    if !output.status.success() {
        bail!("{}", stderr_text(&output).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub(super) fn stderr_text(output: &std::process::Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stderr).into_owned();
    if text.trim().is_empty() {
        text = String::from_utf8_lossy(&output.stdout).into_owned();
    }
    text
}

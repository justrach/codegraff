//! Desktop task-workspace worktrees (#1119, #1121, #1123, #1124, #1118).
//!
//! The engine's isolation rules stay where they are. This module is the
//! surface: one branch per task checkout, a keep gate that will not drop
//! dirty / unique / unverifiable trees, and merge-back that refuses to
//! clobber uncommitted work on the base.
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use anyhow::{Context, Result, bail};
#[path = "task_workspace_git.rs"]
mod git_helpers;
use git_helpers::*;
pub const KEEP_DIRTY: &str = "has uncommitted changes";
pub const KEEP_UNIQUE: &str = "has commits nothing else references";
pub const KEEP_UNVERIFIABLE: &str = "could not verify it is safe to remove";
pub const KEEP_TEARDOWN: &str = "teardown hook failed";
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeepReason {
    Removed,
    Dirty,
    UniqueCommits,
    Unverifiable,
}
impl KeepReason {
    pub fn text(self) -> Option<&'static str> {
        match self {
            Self::Removed => None,
            Self::Dirty => Some(KEEP_DIRTY),
            Self::UniqueCommits => Some(KEEP_UNIQUE),
            Self::Unverifiable => Some(KEEP_UNVERIFIABLE),
        }
    }
}

/// Same proof rule as the engine: every axis must be positively clean.
/// `contained_elsewhere` is true when some ref other than this branch
/// already has `head`. An empty head or a failed status read keeps the tree.
pub fn keep_reason(
    status_ok: bool,
    porcelain: &str,
    head: &str,
    base_commit: &str,
    contained_elsewhere: bool,
) -> KeepReason {
    if !status_ok {
        return KeepReason::Unverifiable;
    }
    if !porcelain.trim().is_empty() {
        return KeepReason::Dirty;
    }
    if head.is_empty() || base_commit.is_empty() {
        return KeepReason::Unverifiable;
    }
    if head == base_commit || contained_elsewhere {
        return KeepReason::Removed;
    }
    KeepReason::UniqueCommits
}

pub fn is_release_or_hotfix(branch: &str) -> bool {
    let name = short_branch(branch);
    name.starts_with("release/")
        || name.starts_with("hotfix/")
        || name.starts_with("release-")
        || name.starts_with("hotfix-")
}

pub fn is_session_scratch(branch: &str) -> bool {
    short_branch(branch).starts_with("worktree-")
}

pub fn is_agent_scratch(branch: &str) -> bool {
    let name = short_branch(branch);
    name.starts_with("graff/agents/") || name.starts_with("agent-")
}

pub fn is_experiment_tree(path: &str, branch: &str) -> bool {
    path.contains(".graff/worktrees/exp-") || short_branch(branch).starts_with("graff/exp/")
}

fn short_branch(branch: &str) -> &str {
    branch
        .trim()
        .strip_prefix("refs/heads/")
        .unwrap_or(branch.trim())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReapVerdict {
    Remove,
    KeepMain,
    KeepLocked,
    KeepRelease,
    KeepSession,
    KeepExperiment,
    KeepDirty,
    KeepUnique,
    KeepUnverifiable,
    KeepForeign,
}

/// Automatic reap only removes finished agent scratch checkouts that the
/// keep gate has proved empty. Release/hotfix trees stay unless the caller
/// has proved they are not in use (`in_use == false`) AND this is an
/// explicit unused sweep (`explicit`). Session scratch (`worktree-*`) and
/// experiment-pool trees are never an automatic reap target (#1124).
pub fn reap_verdict(
    is_main: bool,
    locked: bool,
    in_use: bool,
    explicit: bool,
    path: &str,
    branch: &str,
    keep: KeepReason,
) -> ReapVerdict {
    if is_main {
        return ReapVerdict::KeepMain;
    }
    if locked || in_use {
        return ReapVerdict::KeepLocked;
    }
    if is_experiment_tree(path, branch) {
        return ReapVerdict::KeepExperiment;
    }
    if is_session_scratch(branch) {
        return ReapVerdict::KeepSession;
    }
    if is_release_or_hotfix(branch) && !explicit {
        return ReapVerdict::KeepRelease;
    }
    match keep {
        KeepReason::Dirty => return ReapVerdict::KeepDirty,
        KeepReason::UniqueCommits => return ReapVerdict::KeepUnique,
        KeepReason::Unverifiable => return ReapVerdict::KeepUnverifiable,
        KeepReason::Removed => {}
    }
    if is_release_or_hotfix(branch) {
        // Explicit sweep may drop a clean, merged, unused release checkout.
        return ReapVerdict::Remove;
    }
    if is_agent_scratch(branch) || explicit {
        return ReapVerdict::Remove;
    }
    ReapVerdict::KeepForeign
}

/// A branch is deleted only after its worktree is gone, and only when the
/// commits were landed or the user confirmed a force delete (#1121).
pub fn branch_delete_allowed(worktree_exists: bool, merged_back: bool, confirmed: bool) -> bool {
    !worktree_exists && (merged_back || confirmed)
}

pub fn validate_branch_name(name: &str) -> Result<()> {
    let name = name.trim();
    if name.is_empty() {
        bail!("branch name is required");
    }
    if name.starts_with('-') || name.ends_with('/') || name.ends_with('.') {
        bail!("invalid branch name");
    }
    if name.contains("..") || name.contains("@{") || name.contains(' ') {
        bail!("invalid branch name");
    }
    if name
        .chars()
        .any(|ch| matches!(ch, '~' | '^' | ':' | '?' | '*' | '[' | '\\' | '\0'))
    {
        bail!("invalid branch name");
    }
    Ok(())
}

pub fn slug_branch(branch: &str) -> String {
    let mut slug = String::new();
    for ch in branch.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            slug.push(ch);
        } else {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        "task".into()
    } else {
        slug.chars().take(48).collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeEntry {
    pub path: String,
    pub head: String,
    pub branch: String,
    pub locked: bool,
    pub bare: bool,
}

pub fn parse_worktree_porcelain(text: &str) -> Vec<WorktreeEntry> {
    let mut entries = Vec::new();
    for block in text.split("\n\n") {
        let mut entry = WorktreeEntry {
            path: String::new(),
            head: String::new(),
            branch: String::new(),
            locked: false,
            bare: false,
        };
        for raw in block.lines() {
            let line = raw.trim();
            if let Some(path) = line.strip_prefix("worktree ") {
                entry.path = path.to_string();
            } else if let Some(head) = line.strip_prefix("HEAD ") {
                entry.head = head.to_string();
            } else if let Some(branch) = line.strip_prefix("branch ") {
                entry.branch = branch.to_string();
            } else if line == "locked" || line.starts_with("locked ") {
                entry.locked = true;
            } else if line == "bare" {
                entry.bare = true;
            }
        }
        if !entry.path.is_empty() {
            entries.push(entry);
        }
    }
    entries
}

pub fn contained_elsewhere(refs: &str, own_branch: &str) -> bool {
    let own = short_branch(own_branch);
    refs.lines().any(|raw| {
        let reference = raw.trim().trim_start_matches(['*', '+']).trim();
        !reference.is_empty() && short_branch(reference) != own && reference != own_branch
    })
}

#[derive(Debug, Clone)]
pub struct CreatedTaskWorktree {
    pub path: PathBuf,
    pub branch: String,
    pub base_branch: String,
    pub base_commit: String,
}

pub fn create_task_worktree(
    source: &Path,
    base_branch: Option<&str>,
    branch: &str,
) -> Result<CreatedTaskWorktree> {
    validate_branch_name(branch)?;
    let source = resolve_dir(source)?;
    let main = main_worktree(&source).unwrap_or_else(|| source.clone());
    let base_branch = match base_branch.map(str::trim).filter(|value| !value.is_empty()) {
        Some(name) => name.to_string(),
        None => current_branch(&source).unwrap_or_else(|| "HEAD".into()),
    };
    let base_ref = if base_branch == "HEAD" {
        "HEAD".to_string()
    } else {
        base_branch.clone()
    };
    let base_commit = git_stdout(&source, &["rev-parse", &base_ref])
        .context("could not read the base commit")?
        .trim()
        .to_string();
    if base_commit.is_empty() {
        bail!("could not read the base commit");
    }
    let dest = main
        .join(".graff")
        .join("worktrees")
        .join(format!("task-{}", slug_branch(branch)));
    if dest.exists() {
        bail!("worktree path already exists: {}", dest.display());
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let add = git(
        &main,
        &[
            "worktree",
            "add",
            "-b",
            branch,
            dest.to_string_lossy().as_ref(),
            &base_ref,
        ],
    )?;
    if !add.status.success() {
        bail!(
            "git worktree add failed: {}",
            stderr_text(&add).trim()
        );
    }
    Ok(CreatedTaskWorktree {
        path: dest,
        branch: branch.to_string(),
        base_branch,
        base_commit,
    })
}

#[derive(Debug, Clone)]
pub struct Inspection {
    pub keep: KeepReason,
    pub checkout_bytes: u64,
}

pub fn inspect(path: &Path, base_commit: &str) -> Inspection {
    let checkout_bytes = checkout_bytes(path);
    let status = git(path, &["status", "--porcelain"]);
    let head = git_stdout(path, &["rev-parse", "HEAD"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let branch = git_stdout(path, &["rev-parse", "--abbrev-ref", "HEAD"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let (status_ok, porcelain) = match status {
        Ok(output) if output.status.success() => (true, String::from_utf8_lossy(&output.stdout).into_owned()),
        _ => (false, String::new()),
    };
    let contained = git_stdout(
        path,
        &[
            "branch",
            "--all",
            "--contains",
            &head,
            "--format=%(refname)",
        ],
    )
    .map(|refs| contained_elsewhere(&refs, &branch))
    .unwrap_or(false);
    Inspection {
        keep: keep_reason(status_ok, &porcelain, &head, base_commit, contained),
        checkout_bytes,
    }
}

pub fn remove_checkout(path: &Path, force: bool) -> Result<()> {
    let repo = path;
    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    let path_string = path.to_string_lossy().into_owned();
    args.push(&path_string);
    // `worktree remove` must run from a checkout that is not the one being removed.
    let main = main_worktree(path).unwrap_or_else(|| path.to_path_buf());
    let cwd = if main == path {
        path
    } else {
        &main
    };
    let output = git(cwd, &args)?;
    if output.status.success() {
        return Ok(());
    }
    // Fall back to the source repo if `path` itself was already unusable.
    let _ = repo;
    bail!("could not remove worktree: {}", stderr_text(&output).trim());
}

pub fn delete_branch(repo: &Path, branch: &str, force: bool) -> Result<()> {
    let flag = if force { "-D" } else { "-d" };
    let output = git(repo, &["branch", flag, branch])?;
    if output.status.success() {
        Ok(())
    } else {
        bail!("could not delete branch: {}", stderr_text(&output).trim())
    }
}

/// Lands `branch` onto the base checkout as one commit. Refuses when the
/// base checkout has uncommitted tracked work — a recovery reset would eat it.
pub fn merge_back(base_checkout: &Path, branch: &str) -> Result<()> {
    if tracked_dirty(base_checkout)? {
        bail!("base checkout has uncommitted changes — commit or stash them before merge-back");
    }
    let merge = git(base_checkout, &["merge", "--squash", branch])?;
    if !merge.status.success() {
        let _ = git(base_checkout, &["reset", "--hard", "HEAD"]);
        bail!(
            "couldn't land {branch} — it overlaps changes already on the base. Base left clean, worktree intact."
        );
    }
    let message = format!("land {branch}\n\nCo-Authored-By: Codegraff <blackfloofie@codegraff.com>");
    let commit = git(base_checkout, &["commit", "-m", &message])?;
    if !commit.status.success() {
        let _ = git(base_checkout, &["reset", "--hard", "HEAD"]);
        let detail = stderr_text(&commit);
        if detail.contains("nothing to commit") || String::from_utf8_lossy(&commit.stdout).contains("nothing to commit")
        {
            bail!("nothing to land from {branch} — worktree left intact");
        }
        bail!("git commit failed — worktree left intact: {}", detail.trim());
    }
    Ok(())
}

pub fn update_from_base(worktree: &Path, base: &str) -> Result<()> {
    if tracked_dirty(worktree)? {
        bail!("workspace has uncommitted changes — commit or stash them before updating from {base}");
    }
    let output = git(worktree, &["merge", "--no-edit", base])?;
    if output.status.success() {
        Ok(())
    } else {
        let _ = git(worktree, &["merge", "--abort"]);
        bail!(
            "could not update from {base}: {}",
            stderr_text(&output).trim()
        );
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeProof {
    Merged,
    NotMerged,
    Unknown,
}

pub fn proven_merged_local(repo: &Path, branch: &str, base: &str) -> MergeProof {
    match git(repo, &["merge-base", "--is-ancestor", branch, base]) {
        Ok(output) if output.status.success() => MergeProof::Merged,
        Ok(output) if output.status.code() == Some(1) => MergeProof::NotMerged,
        _ => MergeProof::Unknown,
    }
}

/// `gh` is extra proof for squash merges, which are not ancestors of the base.
/// A missing or timed-out `gh` does not count as "not merged".
pub fn proven_merged(repo: &Path, branch: &str, base: &str) -> MergeProof {
    match proven_merged_local(repo, branch, base) {
        MergeProof::Merged => return MergeProof::Merged,
        MergeProof::Unknown => return MergeProof::Unknown,
        MergeProof::NotMerged => {}
    }
    match gh_merged_pr(repo, branch) {
        Some(true) => MergeProof::Merged,
        Some(false) => MergeProof::NotMerged,
        None => MergeProof::NotMerged,
    }
}

pub fn worktree_exists(path: &Path) -> bool {
    path.join(".git").exists() || path.is_dir() && git(path, &["rev-parse", "--is-inside-work-tree"]).ok().is_some_and(|o| o.status.success())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptOutcome {
    pub ok: bool,
    pub output: String,
}

pub fn run_script(cwd: &Path, script: &str) -> ScriptOutcome {
    let script = script.trim();
    if script.is_empty() {
        return ScriptOutcome {
            ok: true,
            output: String::new(),
        };
    }
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(script)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match command.output() {
        Ok(output) => {
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            let err = String::from_utf8_lossy(&output.stderr);
            if !err.is_empty() {
                if !text.is_empty() && !text.ends_with('\n') {
                    text.push('\n');
                }
                text.push_str(&err);
            }
            if text.len() > 16 * 1024 {
                text.truncate(16 * 1024);
                text.push_str("\n…");
            }
            ScriptOutcome {
                ok: output.status.success(),
                output: text,
            }
        }
        Err(error) => ScriptOutcome {
            ok: false,
            output: format!("failed to run setup/run script: {error}"),
        },
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewDiff {
    pub stat: String,
    pub patch: String,
}

pub fn review_diff(worktree: &Path, base: &str) -> Result<ReviewDiff> {
    let stat = git_stdout(worktree, &["diff", "--stat", &format!("{base}...HEAD")])
        .unwrap_or_default();
    let committed = git_stdout(worktree, &["diff", &format!("{base}...HEAD")]).unwrap_or_default();
    let uncommitted = git_stdout(worktree, &["diff"]).unwrap_or_default();
    let mut patch = String::new();
    if !committed.trim().is_empty() {
        patch.push_str(&committed);
    }
    if !uncommitted.trim().is_empty() {
        if !patch.is_empty() && !patch.ends_with('\n') {
            patch.push('\n');
        }
        patch.push_str(&uncommitted);
    }
    if patch.len() > 200_000 {
        patch.truncate(200_000);
        patch.push_str("\n… diff truncated\n");
    }
    Ok(ReviewDiff { stat, patch })
}

pub fn checkout_bytes(path: &Path) -> u64 {
    let Ok(output) = Command::new("du")
        .args(["-sk"])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    else {
        return 0;
    };
    if !output.status.success() {
        return 0;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let kb = text.split_whitespace().next().unwrap_or("0");
    kb.parse::<u64>().unwrap_or(0).saturating_mul(1024)
}

fn tracked_dirty(path: &Path) -> Result<bool> {
    let output = git(path, &["status", "--porcelain"])?;
    if !output.status.success() {
        bail!("could not read git status");
    }
    let text = String::from_utf8_lossy(&output.stdout);
    Ok(text.lines().any(|line| {
        let line = line.trim_end();
        line.len() >= 2 && !line.starts_with("??")
    }))
}

fn current_branch(path: &Path) -> Option<String> {
    let name = git_stdout(path, &["rev-parse", "--abbrev-ref", "HEAD"]).ok()?;
    let name = name.trim();
    if name.is_empty() || name == "HEAD" {
        None
    } else {
        Some(name.to_string())
    }
}

pub fn repo_root(path: &Path) -> PathBuf {
    main_worktree(path).unwrap_or_else(|| path.to_path_buf())
}

fn main_worktree(path: &Path) -> Option<PathBuf> {
    let common = git_stdout(path, &["rev-parse", "--git-common-dir"]).ok()?;
    let common = PathBuf::from(common.trim());
    let common = if common.is_absolute() {
        common
    } else {
        path.join(common)
    };
    let main = common.parent()?;
    if main.as_os_str().is_empty() {
        return None;
    }
    Some(main.to_path_buf())
}


#[cfg(test)]
#[path = "task_workspace_tests.rs"]
mod tests;

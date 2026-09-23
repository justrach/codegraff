    use super::*;

    #[test]
    fn keep_reason_requires_proof_on_every_axis() {
        assert_eq!(
            keep_reason(true, "", "abc", "abc", false),
            KeepReason::Removed
        );
        assert_eq!(
            keep_reason(true, "", "def", "abc", true),
            KeepReason::Removed
        );
        assert_eq!(
            keep_reason(true, " M src/a.rs\n", "abc", "abc", true),
            KeepReason::Dirty
        );
        assert_eq!(
            keep_reason(true, "?? new.rs\n", "abc", "abc", true),
            KeepReason::Dirty
        );
        assert_eq!(
            keep_reason(true, "", "def", "abc", false),
            KeepReason::UniqueCommits
        );
        assert_eq!(
            keep_reason(false, "", "abc", "abc", true),
            KeepReason::Unverifiable
        );
        assert_eq!(
            keep_reason(true, "", "", "abc", true),
            KeepReason::Unverifiable
        );
    }

    #[test]
    fn reap_keeps_main_release_session_and_dirty_agent_trees() {
        assert_eq!(
            reap_verdict(true, false, false, true, "/repo", "main", KeepReason::Removed),
            ReapVerdict::KeepMain
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                true,
                true,
                "/repo/.graff/worktrees/rel",
                "release/v1",
                KeepReason::Removed
            ),
            ReapVerdict::KeepLocked
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                false,
                false,
                "/repo/.graff/worktrees/rel",
                "hotfix/urgent",
                KeepReason::Removed
            ),
            ReapVerdict::KeepRelease
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                false,
                false,
                "/repo/.graff/worktrees/session-1",
                "worktree-session-1",
                KeepReason::Removed
            ),
            ReapVerdict::KeepSession
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                false,
                false,
                "/repo/.graff/worktrees/agent-1",
                "graff/agents/sa-1",
                KeepReason::Dirty
            ),
            ReapVerdict::KeepDirty
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                false,
                false,
                "/repo/.graff/worktrees/agent-1",
                "graff/agents/sa-1",
                KeepReason::Removed
            ),
            ReapVerdict::Remove
        );
        assert_eq!(
            reap_verdict(
                false,
                false,
                false,
                false,
                "/repo/.worktrees/mine",
                "feature/mine",
                KeepReason::Removed
            ),
            ReapVerdict::KeepForeign
        );
    }

    #[test]
    fn branch_is_not_deleted_while_its_worktree_exists() {
        assert!(!branch_delete_allowed(true, true, true));
        assert!(!branch_delete_allowed(false, false, false));
        assert!(branch_delete_allowed(false, true, false));
        assert!(branch_delete_allowed(false, false, true));
    }

    #[test]
    fn porcelain_parser_reads_locked_linked_trees() {
        let entries = parse_worktree_porcelain(
            "worktree /repo\nHEAD aaa\nbranch refs/heads/main\n\nworktree /repo/.graff/worktrees/a\nHEAD bbb\nbranch refs/heads/graff/agents/a\nlocked\n",
        );
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].branch, "refs/heads/graff/agents/a");
        assert!(entries[1].locked);
        assert!(!contained_elsewhere(
            "refs/heads/graff/agents/a\n",
            "refs/heads/graff/agents/a"
        ));
        assert!(contained_elsewhere(
            "refs/heads/graff/agents/a\nrefs/heads/main\n",
            "refs/heads/graff/agents/a"
        ));
    }

    #[test]
    fn create_refuses_to_clobber_and_merge_back_refuses_a_dirty_base() {
        let root = std::env::temp_dir().join(format!(
            "codegraff-task-wt-{}",
            uuid_nonce()
        ));
        fs::create_dir_all(&root).unwrap();
        git_ok(&root, &["init", "-b", "main"]);
        git_ok(&root, &["config", "user.email", "test@example.com"]);
        git_ok(&root, &["config", "user.name", "test"]);
        fs::write(root.join("readme.txt"), "base\n").unwrap();
        git_ok(&root, &["add", "readme.txt"]);
        git_ok(&root, &["commit", "-m", "base"]);

        let created = create_task_worktree(&root, Some("main"), "feature/task-one").unwrap();
        assert!(created.path.join("readme.txt").is_file());
        assert_eq!(created.base_branch, "main");
        assert!(inspect(&created.path, &created.base_commit).keep == KeepReason::Removed);
        update_from_base(&created.path, "main").unwrap();

        fs::write(created.path.join("task.txt"), "work\n").unwrap();
        assert_eq!(
            inspect(&created.path, &created.base_commit).keep,
            KeepReason::Dirty
        );
        let failed = run_script(&created.path, "echo hi && false");
        assert!(!failed.ok);
        assert!(failed.output.contains("hi"));

        fs::write(root.join("readme.txt"), "dirty base\n").unwrap();
        let merge_err = merge_back(&root, "feature/task-one").unwrap_err().to_string();
        assert!(merge_err.contains("uncommitted"));
        // The dirty base file is still the user's edit, not a reset.
        assert_eq!(fs::read_to_string(root.join("readme.txt")).unwrap(), "dirty base\n");

        git_ok(&root, &["checkout", "--", "readme.txt"]);
        git_ok(&created.path, &["add", "task.txt"]);
        git_ok(&created.path, &["commit", "-m", "task"]);
        assert_eq!(
            inspect(&created.path, &created.base_commit).keep,
            KeepReason::UniqueCommits
        );
        merge_back(&root, "feature/task-one").unwrap();
        assert_eq!(
            proven_merged_local(&root, "feature/task-one", "main"),
            MergeProof::NotMerged,
            "squash merge is not an ancestor; the branch itself is the proof of landing"
        );
        assert!(fs::read_to_string(root.join("task.txt")).unwrap().contains("work"));

        let review = review_diff(&created.path, "main").unwrap();
        assert!(review.stat.contains("task.txt") || review.patch.contains("task"));

        assert!(branch_delete_allowed(true, true, true) == false);
        remove_checkout(&created.path, false).unwrap();
        assert!(branch_delete_allowed(false, true, false));
        // Squash land is not `git branch -d` merged; confirmation uses -D.
        assert!(delete_branch(&root, "feature/task-one", false).is_err());
        delete_branch(&root, "feature/task-one", true).unwrap();
        let _ = fs::remove_dir_all(&root);
    }

    fn uuid_nonce() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )
    }

    fn git_ok(cwd: &Path, args: &[&str]) {
        let output = git(cwd, args).unwrap();
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            stderr_text(&output)
        );
    }

    #[test]
    fn script_failure_is_visible() {
        let root = std::env::temp_dir().join(format!("codegraff-task-script-{}", uuid_nonce()));
        fs::create_dir_all(&root).unwrap();
        let outcome = run_script(&root, "echo setup-failed >&2; exit 3");
        assert!(!outcome.ok);
        assert!(outcome.output.contains("setup-failed"));
        let _ = fs::remove_dir_all(&root);
    }

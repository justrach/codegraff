use std::path::Path;

use diesel::prelude::*;
use diesel::sql_types::{BigInt, Nullable, Text};
use diesel::{QueryableByName, RunQueryDsl, sql_query};

use super::support::canonicalize_workspace_removal_path;
use super::ProjectStore;

#[derive(Debug, Clone, QueryableByName)]
pub struct TaskWorkspaceRecord {
    #[diesel(sql_type = Text)]
    pub path: String,
    #[diesel(sql_type = Text)]
    pub branch: String,
    #[diesel(sql_type = Text)]
    pub base_branch: String,
    #[diesel(sql_type = Text)]
    pub base_commit: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub setup_script: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub run_script: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub teardown_script: Option<String>,
    #[diesel(sql_type = BigInt)]
    pub setup_ran: i64,
    #[diesel(sql_type = Nullable<Text>)]
    pub setup_error: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub run_error: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub keep_reason: Option<String>,
    #[diesel(sql_type = BigInt)]
    pub merged_back: i64,
}

impl ProjectStore {
    pub fn upsert_task_workspace(&self, record: &TaskWorkspaceRecord) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query(
                "
                INSERT INTO task_workspaces (
                  path, branch, base_branch, base_commit, setup_script, run_script,
                  teardown_script, setup_ran, setup_error, run_error, keep_reason, merged_back
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                ON CONFLICT(path) DO UPDATE SET
                  branch = excluded.branch,
                  base_branch = excluded.base_branch,
                  base_commit = excluded.base_commit,
                  setup_script = excluded.setup_script,
                  run_script = excluded.run_script,
                  teardown_script = excluded.teardown_script,
                  setup_ran = excluded.setup_ran,
                  setup_error = excluded.setup_error,
                  run_error = excluded.run_error,
                  keep_reason = excluded.keep_reason,
                  merged_back = excluded.merged_back
                ",
            )
            .bind::<Text, _>(&record.path)
            .bind::<Text, _>(&record.branch)
            .bind::<Text, _>(&record.base_branch)
            .bind::<Text, _>(&record.base_commit)
            .bind::<Nullable<Text>, _>(record.setup_script.as_deref())
            .bind::<Nullable<Text>, _>(record.run_script.as_deref())
            .bind::<Nullable<Text>, _>(record.teardown_script.as_deref())
            .bind::<BigInt, _>(record.setup_ran)
            .bind::<Nullable<Text>, _>(record.setup_error.as_deref())
            .bind::<Nullable<Text>, _>(record.run_error.as_deref())
            .bind::<Nullable<Text>, _>(record.keep_reason.as_deref())
            .bind::<BigInt, _>(record.merged_back)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn list_task_workspaces(&self) -> anyhow::Result<Vec<TaskWorkspaceRecord>> {
        self.with_connection(|connection| {
            let rows = sql_query(
                "
                SELECT path, branch, base_branch, base_commit, setup_script, run_script,
                       teardown_script, setup_ran, setup_error, run_error, keep_reason, merged_back
                FROM task_workspaces
                ORDER BY path
                ",
            )
            .load(connection)?;
            Ok(rows)
        })
    }

    pub fn get_task_workspace(&self, path: &Path) -> anyhow::Result<Option<TaskWorkspaceRecord>> {
        let canonical = canonicalize_workspace_removal_path(path);
        self.with_connection(|connection| {
            let row = sql_query(
                "
                SELECT path, branch, base_branch, base_commit, setup_script, run_script,
                       teardown_script, setup_ran, setup_error, run_error, keep_reason, merged_back
                FROM task_workspaces
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(canonical)
            .get_result(connection)
            .optional()?;
            Ok(row)
        })
    }

    pub fn set_task_keep_reason(&self, path: &str, reason: Option<&str>) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query("UPDATE task_workspaces SET keep_reason = ?2 WHERE path = ?1")
                .bind::<Text, _>(path)
                .bind::<Nullable<Text>, _>(reason)
                .execute(connection)?;
            Ok(())
        })
    }

    pub fn set_task_setup_result(
        &self,
        path: &str,
        error: Option<&str>,
    ) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query(
                "UPDATE task_workspaces SET setup_ran = 1, setup_error = ?2 WHERE path = ?1",
            )
            .bind::<Text, _>(path)
            .bind::<Nullable<Text>, _>(error)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn set_task_merged_back(&self, path: &str) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query("UPDATE task_workspaces SET merged_back = 1, keep_reason = NULL WHERE path = ?1")
                .bind::<Text, _>(path)
                .execute(connection)?;
            Ok(())
        })
    }

    pub fn delete_task_workspace(&self, path: &str) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query("DELETE FROM task_workspaces WHERE path = ?1")
                .bind::<Text, _>(path)
                .execute(connection)?;
            Ok(())
        })
    }
}

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::Context;
use diesel::connection::SimpleConnection;
use diesel::prelude::*;
use diesel::sql_types::{BigInt, Nullable, Text};
use diesel::{QueryableByName, RunQueryDsl, SqliteConnection, sql_query};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegisteredWorkspaceKind {
    Project,
    ManagedChat,
}

#[derive(Debug, Clone)]
pub struct RegisteredWorkspace {
    pub kind: RegisteredWorkspaceKind,
    pub path: PathBuf,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RegisteredWorkspaceMetadata {
    pub kind: RegisteredWorkspaceKind,
    pub display_name: Option<String>,
}

#[derive(Debug)]
pub struct ProjectStore {
    db_path: PathBuf,
    managed_chats_root: PathBuf,
    connection_lock: Mutex<()>,
}

#[derive(Debug, Clone, QueryableByName)]
pub struct SavedWorkspaceSummaryRecord {
    #[diesel(sql_type = Text)]
    pub id: String,
    #[diesel(sql_type = Text)]
    pub name: String,
    #[diesel(sql_type = BigInt)]
    pub updated_at: i64,
}

#[derive(Debug, Clone, QueryableByName)]
pub struct SavedWorkspaceRecord {
    #[diesel(sql_type = Text)]
    pub id: String,
    #[diesel(sql_type = Text)]
    pub name: String,
    #[diesel(sql_type = Text)]
    pub layout_json: String,
    #[diesel(sql_type = BigInt)]
    pub updated_at: i64,
}

impl ProjectStore {
    pub fn new(db_path: PathBuf, managed_chats_root: PathBuf) -> anyhow::Result<Self> {
        let store = Self {
            db_path,
            managed_chats_root,
            connection_lock: Mutex::new(()),
        };
        store.init()?;
        Ok(store)
    }

    pub fn add_project(&self, path: &Path) -> anyhow::Result<()> {
        let canonical = canonicalize_project_path(path)?;
        self.with_connection(|connection| {
            sql_query(
                "
                INSERT INTO opened_projects (path, last_opened_at)
                VALUES (?1, unixepoch())
                ON CONFLICT(path) DO NOTHING
                ",
            )
            .bind::<Text, _>(canonical)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn create_managed_chat_workspace(&self) -> anyhow::Result<PathBuf> {
        fs::create_dir_all(&self.managed_chats_root).with_context(|| {
            format!(
                "Failed to create managed chat workspace directory at {}",
                self.managed_chats_root.display()
            )
        })?;

        let managed_chat_path = self
            .managed_chats_root
            .join(format!("chat_{}", Uuid::new_v4().simple()));
        fs::create_dir_all(&managed_chat_path).with_context(|| {
            format!(
                "Failed to create managed chat workspace at {}",
                managed_chat_path.display()
            )
        })?;

        let canonical = canonicalize_project_path(&managed_chat_path)?;
        self.with_connection(|connection| {
            sql_query(
                "
                INSERT INTO managed_chat_workspaces (path, created_at, last_opened_at)
                VALUES (?1, unixepoch(), unixepoch())
                ",
            )
            .bind::<Text, _>(&canonical)
            .execute(connection)?;
            Ok(())
        })?;

        Ok(PathBuf::from(canonical))
    }

    pub fn list_workspaces(&self) -> anyhow::Result<Vec<RegisteredWorkspace>> {
        self.with_connection(|connection| {
            let rows: Vec<RegisteredWorkspaceRow> = sql_query(
                "
                SELECT path, kind, display_name
                FROM (
                  SELECT path, 'project' AS kind, display_name, last_opened_at
                  FROM opened_projects
                  UNION ALL
                  SELECT path, 'managed_chat' AS kind, display_name, last_opened_at
                  FROM managed_chat_workspaces
                )
                ORDER BY last_opened_at DESC, path ASC
                ",
            )
            .load(connection)?;

            Ok(rows
                .into_iter()
                .map(|row| RegisteredWorkspace {
                    kind: parse_workspace_kind(&row.kind),
                    display_name: normalize_display_name(row.display_name.as_deref()),
                    path: PathBuf::from(row.path),
                })
                .filter(|workspace| workspace.path.exists())
                .collect())
        })
    }

    pub fn get_workspace_registration(
        &self,
        path: &Path,
    ) -> anyhow::Result<Option<RegisteredWorkspaceMetadata>> {
        let canonical = canonicalize_project_path(path)?;
        self.with_connection(|connection| {
            let rows: Vec<RegisteredWorkspaceRegistrationRow> = sql_query(
                "
                SELECT kind, display_name
                FROM (
                  SELECT 'project' AS kind, display_name
                  FROM opened_projects
                  WHERE path = ?1
                  UNION ALL
                  SELECT 'managed_chat' AS kind, display_name
                  FROM managed_chat_workspaces
                  WHERE path = ?1
                )
                LIMIT 1
                ",
            )
            .bind::<Text, _>(canonical)
            .load(connection)?;

            Ok(rows
                .into_iter()
                .next()
                .map(|row| RegisteredWorkspaceMetadata {
                    kind: parse_workspace_kind(&row.kind),
                    display_name: normalize_display_name(row.display_name.as_deref()),
                }))
        })
    }

    pub fn get_workspace_kind(
        &self,
        path: &Path,
    ) -> anyhow::Result<Option<RegisteredWorkspaceKind>> {
        Ok(self
            .get_workspace_registration(path)?
            .map(|registration| registration.kind))
    }

    pub fn set_workspace_display_name(
        &self,
        path: &Path,
        display_name: Option<&str>,
    ) -> anyhow::Result<()> {
        let canonical = canonicalize_project_path(path)?;
        let display_name = normalize_display_name(display_name);
        self.with_connection(|connection| {
            let mut updated_rows = 0usize;
            updated_rows += sql_query(
                "
                UPDATE opened_projects
                SET display_name = ?2
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(&canonical)
            .bind::<Nullable<Text>, _>(display_name.clone())
            .execute(connection)?;

            updated_rows += sql_query(
                "
                UPDATE managed_chat_workspaces
                SET display_name = ?2
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(&canonical)
            .bind::<Nullable<Text>, _>(display_name)
            .execute(connection)?;

            if updated_rows == 0 {
                anyhow::bail!("Workspace is not registered.");
            }

            Ok(())
        })
    }

    pub fn touch_managed_chat_workspace(&self, path: &Path) -> anyhow::Result<()> {
        let canonical = canonicalize_project_path(path)?;
        self.with_connection(|connection| {
            sql_query(
                "
                UPDATE managed_chat_workspaces
                SET last_opened_at = unixepoch()
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(canonical)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn archive_workspace(&self, path: &Path) -> anyhow::Result<()> {
        let canonical = canonicalize_workspace_removal_path(path);
        self.with_connection(|connection| {
            sql_query(
                "
                DELETE FROM opened_projects
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(&canonical)
            .execute(connection)?;

            sql_query(
                "
                DELETE FROM managed_chat_workspaces
                WHERE path = ?1
                ",
            )
            .bind::<Text, _>(&canonical)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn delete_conversation_layout(&self, conversation_id: &str) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query(
                "
                DELETE FROM conversation_layouts
                WHERE conversation_id = ?1
                ",
            )
            .bind::<Text, _>(conversation_id)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn save_conversation_layout(
        &self,
        conversation_id: &str,
        layout_json: &str,
    ) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query(
                "
                INSERT INTO conversation_layouts (conversation_id, layout_json, updated_at)
                VALUES (?1, ?2, unixepoch())
                ON CONFLICT(conversation_id) DO UPDATE SET
                  layout_json = excluded.layout_json,
                  updated_at = excluded.updated_at
                ",
            )
            .bind::<Text, _>(conversation_id)
            .bind::<Text, _>(layout_json)
            .execute(connection)?;
            Ok(())
        })
    }

    pub fn get_conversation_layout(&self, conversation_id: &str) -> anyhow::Result<Option<String>> {
        self.with_connection(|connection| {
            let rows: Vec<ConversationLayoutRow> = sql_query(
                "
                SELECT layout_json
                FROM conversation_layouts
                WHERE conversation_id = ?1
                LIMIT 1
                ",
            )
            .bind::<Text, _>(conversation_id)
            .load(connection)?;

            Ok(rows.into_iter().next().map(|row| row.layout_json))
        })
    }

    pub fn create_saved_workspace(
        &self,
        workspace_id: &str,
        name: &str,
        layout_json: &str,
    ) -> anyhow::Result<SavedWorkspaceRecord> {
        self.with_connection(|connection| {
            connection.transaction(|connection| {
                sql_query(
                    "
                    INSERT INTO saved_workspaces (id, name, created_at, updated_at)
                    VALUES (?1, ?2, unixepoch(), unixepoch())
                    ",
                )
                .bind::<Text, _>(workspace_id)
                .bind::<Text, _>(name)
                .execute(connection)?;

                sql_query(
                    "
                    INSERT INTO saved_workspace_layouts (workspace_id, layout_json, updated_at)
                    VALUES (?1, ?2, unixepoch())
                    ",
                )
                .bind::<Text, _>(workspace_id)
                .bind::<Text, _>(layout_json)
                .execute(connection)?;

                load_saved_workspace_record(connection, workspace_id)
            })
        })
    }

    pub fn update_saved_workspace_layout(
        &self,
        workspace_id: &str,
        layout_json: &str,
    ) -> anyhow::Result<SavedWorkspaceRecord> {
        self.with_connection(|connection| {
            connection.transaction(|connection| {
                sql_query(
                    "
                    UPDATE saved_workspaces
                    SET updated_at = unixepoch()
                    WHERE id = ?1
                    ",
                )
                .bind::<Text, _>(workspace_id)
                .execute(connection)?;

                sql_query(
                    "
                    INSERT INTO saved_workspace_layouts (workspace_id, layout_json, updated_at)
                    VALUES (?1, ?2, unixepoch())
                    ON CONFLICT(workspace_id) DO UPDATE SET
                      layout_json = excluded.layout_json,
                      updated_at = excluded.updated_at
                    ",
                )
                .bind::<Text, _>(workspace_id)
                .bind::<Text, _>(layout_json)
                .execute(connection)?;

                load_saved_workspace_record(connection, workspace_id)
            })
        })
    }

    pub fn list_saved_workspaces(&self) -> anyhow::Result<Vec<SavedWorkspaceSummaryRecord>> {
        self.with_connection(|connection| {
            let rows = sql_query(
                "
                SELECT id, name, updated_at
                FROM saved_workspaces
                ORDER BY created_at DESC, id ASC
                ",
            )
            .load(connection)?;

            Ok(rows)
        })
    }

    pub fn get_saved_workspace(
        &self,
        workspace_id: &str,
    ) -> anyhow::Result<Option<SavedWorkspaceRecord>> {
        self.with_connection(|connection| {
            load_optional_saved_workspace_record(connection, workspace_id)
        })
    }

    pub fn rename_saved_workspace(
        &self,
        workspace_id: &str,
        name: &str,
    ) -> anyhow::Result<SavedWorkspaceRecord> {
        let trimmed_name = name.trim();
        if trimmed_name.is_empty() {
            anyhow::bail!("Workspace name cannot be empty.");
        }

        self.with_connection(|connection| {
            connection.transaction(|connection| {
                sql_query(
                    "
                    UPDATE saved_workspaces
                    SET name = ?2,
                        updated_at = unixepoch()
                    WHERE id = ?1
                    ",
                )
                .bind::<Text, _>(workspace_id)
                .bind::<Text, _>(trimmed_name)
                .execute(connection)?;

                load_saved_workspace_record(connection, workspace_id)
            })
        })
    }

    pub fn delete_saved_workspace(&self, workspace_id: &str) -> anyhow::Result<()> {
        self.with_connection(|connection| {
            sql_query(
                "
                DELETE FROM saved_workspaces
                WHERE id = ?1
                ",
            )
            .bind::<Text, _>(workspace_id)
            .execute(connection)?;
            Ok(())
        })
    }

    fn init(&self) -> anyhow::Result<()> {
        if let Some(parent) = self.db_path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "Failed to create project registry directory at {}",
                    parent.display()
                )
            })?;
        }

        self.with_connection(|connection| {
            connection.batch_execute(
                "
                CREATE TABLE IF NOT EXISTS opened_projects (
                  path TEXT PRIMARY KEY,
                  last_opened_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS managed_chat_workspaces (
                  path TEXT PRIMARY KEY,
                  created_at INTEGER NOT NULL,
                  last_opened_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS conversation_layouts (
                  conversation_id TEXT PRIMARY KEY,
                  layout_json TEXT NOT NULL,
                  updated_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS saved_workspaces (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS saved_workspace_layouts (
                  workspace_id TEXT PRIMARY KEY,
                  layout_json TEXT NOT NULL,
                  updated_at INTEGER NOT NULL,
                  FOREIGN KEY(workspace_id) REFERENCES saved_workspaces(id) ON DELETE CASCADE
                );
                ",
            )?;
            ensure_column_exists(connection, "opened_projects", "display_name", "TEXT")?;
            ensure_column_exists(
                connection,
                "managed_chat_workspaces",
                "display_name",
                "TEXT",
            )?;
            Ok(())
        })
    }

    fn open(&self) -> anyhow::Result<SqliteConnection> {
        let mut connection = SqliteConnection::establish(self.db_path.to_string_lossy().as_ref())
            .with_context(|| {
            format!(
                "Failed to open project registry database at {}",
                self.db_path.display()
            )
        })?;
        connection.batch_execute(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA busy_timeout = 5000;
            PRAGMA foreign_keys = ON;
            ",
        )?;
        Ok(connection)
    }

    fn with_connection<T>(
        &self,
        operation: impl FnOnce(&mut SqliteConnection) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let _connection_lock = self
            .connection_lock
            .lock()
            .expect("project store mutex poisoned");
        let mut connection = self.open()?;
        operation(&mut connection)
    }
}

#[derive(QueryableByName)]
struct RegisteredWorkspaceRow {
    #[diesel(sql_type = Text)]
    path: String,
    #[diesel(sql_type = Text)]
    kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    display_name: Option<String>,
}

#[derive(QueryableByName)]
struct RegisteredWorkspaceRegistrationRow {
    #[diesel(sql_type = Text)]
    kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    display_name: Option<String>,
}

#[derive(QueryableByName)]
struct ConversationLayoutRow {
    #[diesel(sql_type = Text)]
    layout_json: String,
}

#[derive(QueryableByName)]
struct TableColumnRow {
    #[diesel(sql_type = Text)]
    name: String,
}

fn canonicalize_project_path(path: &Path) -> anyhow::Result<String> {
    Ok(path
        .canonicalize()
        .with_context(|| format!("Failed to canonicalize project path {}", path.display()))?
        .to_string_lossy()
        .into_owned())
}

fn canonicalize_workspace_removal_path(path: &Path) -> String {
    canonicalize_project_path(path).unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

fn parse_workspace_kind(value: &str) -> RegisteredWorkspaceKind {
    match value {
        "managed_chat" => RegisteredWorkspaceKind::ManagedChat,
        _ => RegisteredWorkspaceKind::Project,
    }
}

fn normalize_display_name(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn ensure_column_exists(
    connection: &mut SqliteConnection,
    table: &str,
    column: &str,
    definition: &str,
) -> anyhow::Result<()> {
    let rows: Vec<TableColumnRow> =
        sql_query(format!("SELECT name FROM pragma_table_info('{table}')")).load(connection)?;
    if rows.iter().any(|existing| existing.name == column) {
        return Ok(());
    }

    connection.batch_execute(&format!(
        "ALTER TABLE {table} ADD COLUMN {column} {definition};"
    ))?;
    Ok(())
}

fn load_saved_workspace_record(
    connection: &mut SqliteConnection,
    workspace_id: &str,
) -> anyhow::Result<SavedWorkspaceRecord> {
    load_optional_saved_workspace_record(connection, workspace_id)?
        .with_context(|| format!("Saved workspace not found: {workspace_id}"))
}

fn load_optional_saved_workspace_record(
    connection: &mut SqliteConnection,
    workspace_id: &str,
) -> anyhow::Result<Option<SavedWorkspaceRecord>> {
    let rows: Vec<SavedWorkspaceRecord> = sql_query(
        "
        SELECT sw.id, sw.name, swl.layout_json, sw.updated_at
        FROM saved_workspaces sw
        INNER JOIN saved_workspace_layouts swl
          ON swl.workspace_id = sw.id
        WHERE sw.id = ?1
        LIMIT 1
        ",
    )
    .bind::<Text, _>(workspace_id)
    .load(connection)?;

    Ok(rows.into_iter().next())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_store() -> anyhow::Result<(ProjectStore, PathBuf)> {
        let root = std::env::temp_dir().join(format!(
            "codegraff-project-store-test-{}",
            Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&root)?;
        let store = ProjectStore::new(root.join("projects.sqlite"), root.join("managed-chats"))?;
        Ok((store, root))
    }

    #[test]
    fn archive_workspace_removes_registry_entry_for_missing_folder() -> anyhow::Result<()> {
        let (store, root) = test_store()?;
        let project_path = root.join("deleted-project");
        fs::create_dir_all(&project_path)?;
        let canonical_project_path = project_path.canonicalize()?;

        store.add_project(&canonical_project_path)?;
        fs::remove_dir_all(&canonical_project_path)?;

        store.archive_workspace(&canonical_project_path)?;
        fs::create_dir_all(&canonical_project_path)?;

        let registered_paths: Vec<PathBuf> = store
            .list_workspaces()?
            .into_iter()
            .map(|workspace| workspace.path)
            .collect();
        assert!(!registered_paths.contains(&canonical_project_path));

        fs::remove_dir_all(root)?;
        Ok(())
    }
}

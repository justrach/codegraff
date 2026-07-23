use std::path::Path;

use anyhow::Context;
use diesel::connection::SimpleConnection;
use diesel::sql_types::{Nullable, Text};
use diesel::{QueryableByName, RunQueryDsl, SqliteConnection, sql_query};

use super::{RegisteredWorkspaceKind, SavedWorkspaceRecord};

#[derive(QueryableByName)]
pub(super) struct RegisteredWorkspaceRow {
    #[diesel(sql_type = Text)]
    pub(super) path: String,
    #[diesel(sql_type = Text)]
    pub(super) kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub(super) display_name: Option<String>,
}

#[derive(QueryableByName)]
pub(super) struct RegisteredWorkspaceRegistrationRow {
    #[diesel(sql_type = Text)]
    pub(super) kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub(super) display_name: Option<String>,
}

#[derive(QueryableByName)]
pub(super) struct ConversationLayoutRow {
    #[diesel(sql_type = Text)]
    pub(super) layout_json: String,
}

#[derive(QueryableByName)]
struct TableColumnRow {
    #[diesel(sql_type = Text)]
    name: String,
}

pub(super) fn canonicalize_project_path(path: &Path) -> anyhow::Result<String> {
    Ok(path
        .canonicalize()
        .with_context(|| format!("Failed to canonicalize project path {}", path.display()))?
        .to_string_lossy()
        .into_owned())
}

pub(super) fn canonicalize_workspace_removal_path(path: &Path) -> String {
    canonicalize_project_path(path).unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

pub(super) fn parse_workspace_kind(value: &str) -> RegisteredWorkspaceKind {
    match value {
        "managed_chat" => RegisteredWorkspaceKind::ManagedChat,
        _ => RegisteredWorkspaceKind::Project,
    }
}

pub(super) fn normalize_display_name(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

pub(super) fn ensure_column_exists(
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

pub(super) fn load_saved_workspace_record(
    connection: &mut SqliteConnection,
    workspace_id: &str,
) -> anyhow::Result<SavedWorkspaceRecord> {
    load_optional_saved_workspace_record(connection, workspace_id)?
        .with_context(|| format!("Saved workspace not found: {workspace_id}"))
}

pub(super) fn load_optional_saved_workspace_record(
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

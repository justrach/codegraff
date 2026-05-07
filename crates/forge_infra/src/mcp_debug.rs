//! Append-only JSONL ring-file capturing recent MCP request/response pairs
//! so users (and AI agents debugging graff) can inspect the literal wire
//! payloads without enabling tracing or reading source.
//!
//! Records land in `<base_path>/debug/mcp-recent.jsonl`, one JSON object per
//! line. When the file exceeds [`MAX_FILE_BYTES`] we truncate it to the last
//! [`KEEP_RECORDS`] lines on the next write — cheap because `metadata().len()`
//! is O(1) and rotation only kicks in occasionally.
//!
//! Surfaced via the `graff debug last-mcp-call` subcommand.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::time::Instant;

use chrono::Utc;
use forge_domain::Environment;
use serde_json::{Map, Value, json};

/// Roughly 4 MiB before we trim. Each MCP record is typically a few hundred
/// bytes to a few KiB, so this keeps thousands of recent calls available.
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;

/// Number of records to keep when trimming.
const KEEP_RECORDS: usize = 500;

/// What happened on a single MCP `call_tool` round-trip.
pub enum McpCallOutcome<'a> {
    /// Success or tool-reported error from the server. The `Value` is the raw
    /// rmcp `CallToolResult` serialized to JSON, so we capture both
    /// `is_error` and `content` faithfully.
    Returned { result_json: &'a Value },
    /// Transport / framework failure — the call never produced a structured
    /// result. The string is the `anyhow` chain.
    Failed { error: &'a str },
}

/// Returns the path to the JSONL ring file. Does not create it.
pub fn debug_path(env: &Environment) -> PathBuf {
    env.base_path.join("debug").join("mcp-recent.jsonl")
}

/// Append one record describing an MCP `call_tool` invocation. Best-effort:
/// any I/O error is logged at WARN and swallowed so debug recording never
/// breaks a real call.
pub fn record(
    env: &Environment,
    server: &str,
    tool: &str,
    args: Option<&Map<String, Value>>,
    started_at: Instant,
    outcome: &McpCallOutcome<'_>,
) {
    let path = debug_path(env);
    if let Err(e) = record_inner(&path, server, tool, args, started_at, outcome) {
        tracing::warn!(error = %e, path = %path.display(), "failed to write mcp-recent.jsonl");
    }
}

fn record_inner(
    path: &PathBuf,
    server: &str,
    tool: &str,
    args: Option<&Map<String, Value>>,
    started_at: Instant,
    outcome: &McpCallOutcome<'_>,
) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Trim before appending if the file is over the cap. Doing it on the
    // write path (rather than periodically) is fine: we only stat() per call.
    if let Ok(meta) = fs::metadata(path)
        && meta.len() > MAX_FILE_BYTES
    {
        trim_to_last(path, KEEP_RECORDS)?;
    }

    let duration_ms = started_at.elapsed().as_millis() as u64;
    let outcome_json = match outcome {
        McpCallOutcome::Returned { result_json } => json!({
            "kind": "returned",
            "result": result_json,
        }),
        McpCallOutcome::Failed { error } => json!({
            "kind": "failed",
            "error": error,
        }),
    };

    let record = json!({
        "timestamp": Utc::now().to_rfc3339(),
        "server": server,
        "tool": tool,
        "duration_ms": duration_ms,
        "request": args.cloned().map(Value::Object).unwrap_or(Value::Null),
        "outcome": outcome_json,
    });

    let line = serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());

    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{line}")?;
    Ok(())
}

fn trim_to_last(path: &PathBuf, keep: usize) -> std::io::Result<()> {
    let file = OpenOptions::new().read(true).open(path)?;
    let lines: Vec<String> = BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .collect();
    let start = lines.len().saturating_sub(keep);
    let kept = &lines[start..];

    let mut tmp = path.clone();
    tmp.set_extension("jsonl.tmp");
    {
        let mut out = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp)?;
        for line in kept {
            writeln!(out, "{line}")?;
        }
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

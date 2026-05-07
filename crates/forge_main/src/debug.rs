//! Implementation of the `graff debug` subcommands. Reads from the JSONL ring
//! file written by [`forge_infra::mcp_debug`] and prints filtered records.

use std::io::{BufRead, BufReader};
use std::path::Path;

use anyhow::{Context, Result};

use crate::cli::LastMcpCallArgs;

/// Print the last N MCP call records (filtered by server/tool if requested)
/// from the on-disk ring file at `<base>/debug/mcp-recent.jsonl`.
///
/// Default output is JSONL (one record per line) so the result is trivially
/// consumable by `jq`, scripts, or AI agents. `--pretty` switches to indented
/// JSON, separated by blank lines, when humans are reading.
pub fn last_mcp_call(args: &LastMcpCallArgs, debug_path: &Path) -> Result<()> {
    if !debug_path.exists() {
        eprintln!(
            "No MCP debug records yet at {}. Trigger an MCP tool call from \
             a graff session and try again.",
            debug_path.display()
        );
        return Ok(());
    }

    let file = std::fs::File::open(debug_path)
        .with_context(|| format!("opening {}", debug_path.display()))?;

    // Read all lines, then filter from the end. The ring file is bounded so
    // this is cheap; doing it in two passes keeps the filter logic simple.
    let lines: Vec<String> = BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .collect();

    let mut matched: Vec<&str> = Vec::with_capacity(args.n);
    for line in lines.iter().rev() {
        if line.trim().is_empty() {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(server) = &args.server
            && value.get("server").and_then(|v| v.as_str()) != Some(server.as_str())
        {
            continue;
        }
        if let Some(tool) = &args.tool
            && value.get("tool").and_then(|v| v.as_str()) != Some(tool.as_str())
        {
            continue;
        }
        matched.push(line.as_str());
        if matched.len() >= args.n {
            break;
        }
    }

    // Restore chronological order (oldest first) for the output.
    matched.reverse();

    for line in matched {
        if args.pretty {
            match serde_json::from_str::<serde_json::Value>(line) {
                Ok(v) => println!("{}\n", serde_json::to_string_pretty(&v).unwrap_or_default()),
                Err(_) => println!("{line}"),
            }
        } else {
            println!("{line}");
        }
    }

    Ok(())
}

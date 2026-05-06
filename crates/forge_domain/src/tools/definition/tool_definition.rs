use derive_setters::Setters;
use schemars::Schema;
use serde::{Deserialize, Serialize};

use crate::ToolName;

/// Optional MCP tool annotations (mirrors the MCP `ToolAnnotations` shape).
///
/// All fields are advisory hints from the server about how the tool behaves.
/// Kept domain-local so `forge_domain` doesn't depend on `rmcp`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Setters)]
#[setters(into, strip_option)]
pub struct ToolAnnotations {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_only_hint: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destructive_hint: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotent_hint: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_world_hint: Option<bool>,
}

///
/// Refer to the specification over here:
/// https://glama.ai/blog/2024-11-25-model-context-protocol-quickstart#server
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Setters)]
#[setters(into, strip_option)]
pub struct ToolDefinition {
    pub name: ToolName,
    pub description: String,
    pub input_schema: Schema,
    /// Optional output schema (MCP `outputSchema`) describing the structure of
    /// `structured_content` results. Populated for MCP tools that advertise it;
    /// `None` for built-ins.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_schema: Option<Schema>,
    /// Optional MCP annotations carrying behavior hints (read-only,
    /// destructive, idempotent, open-world) and an annotation-level title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<ToolAnnotations>,
    /// Optional human-readable title (MCP `title`), distinct from `name`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

impl ToolDefinition {
    /// Create a new ToolDefinition
    pub fn new<N: ToString>(name: N) -> Self {
        ToolDefinition {
            name: ToolName::new(name),
            description: String::new(),
            input_schema: schemars::schema_for!(()), // Empty input schema
            output_schema: None,
            annotations: None,
            title: None,
        }
    }
}

pub trait ToolDescription {
    fn description(&self) -> String;
}

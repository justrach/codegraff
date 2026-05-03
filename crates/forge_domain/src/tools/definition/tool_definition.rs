use derive_setters::Setters;
use schemars::Schema;
use serde::{Deserialize, Serialize};

use crate::ToolName;

/// Syntax used to constrain a custom tool's free-form text input.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ToolGrammarSyntax {
    /// Lark context-free grammar syntax.
    Lark,
    /// Rust-regex-compatible single-line grammar syntax.
    Regex,
}

/// Grammar definition for OpenAI custom tools.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Setters)]
#[setters(into, strip_option)]
pub struct ToolGrammar {
    /// The grammar source provided to the model.
    pub definition: String,
    /// The syntax used by the grammar source.
    pub syntax: ToolGrammarSyntax,
}

impl ToolGrammar {
    /// Creates a new custom tool grammar definition.
    pub fn new(definition: impl ToString, syntax: ToolGrammarSyntax) -> Self {
        Self { definition: definition.to_string(), syntax }
    }
}

/// Definition of a model-callable tool.
///
/// Refer to the specification over here:
/// https://glama.ai/blog/2024-11-25-model-context-protocol-quickstart#server
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Setters)]
#[setters(into, strip_option)]
pub struct ToolDefinition {
    /// The tool name used by the model and tool executor.
    pub name: ToolName,
    /// The natural-language description used to decide when to call the tool.
    pub description: String,
    /// The JSON schema for function tool arguments.
    pub input_schema: Schema,
    /// Optional grammar that makes this an OpenAI custom tool instead of a JSON function tool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grammar: Option<ToolGrammar>,
}

impl ToolDefinition {
    /// Create a new ToolDefinition
    pub fn new<N: ToString>(name: N) -> Self {
        ToolDefinition {
            name: ToolName::new(name),
            description: String::new(),
            input_schema: schemars::schema_for!(()), // Empty input schema
            grammar: None,
        }
    }
}

pub trait ToolDescription {
    /// Returns the natural-language description for this tool.
    fn description(&self) -> String;
}

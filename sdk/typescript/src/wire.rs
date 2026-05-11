//! JSON wire format mirroring `forge_domain::ChatResponse`.
//!
//! `ChatResponse` itself is not `Serialize` — and one of its variants holds an
//! `Arc<Notify>` which can't cross the FFI boundary anyway — so we project it
//! into a tagged enum we control. The `From<ChatResponse>` impl also fires the
//! tool-execution notify so the SDK behaves like `--print` mode (auto-approve).

use forge_domain::{
    Category, Cause, ChatResponse, ChatResponseContent, InterruptionReason, TitleFormat,
};
use serde::Serialize;

#[derive(Serialize)]
#[serde(tag = "type")]
pub enum WireEvent {
    TaskMessage {
        content: WireContent,
    },
    TaskReasoning {
        content: String,
    },
    TaskComplete,
    ToolCallStart {
        tool_call: serde_json::Value,
    },
    ToolCallEnd {
        result: serde_json::Value,
    },
    RetryAttempt {
        cause: String,
        duration_ms: u64,
    },
    Interrupt {
        reason: WireInterrupt,
    },
}

#[derive(Serialize)]
#[serde(tag = "kind")]
pub enum WireContent {
    ToolInput {
        title: String,
        sub_title: Option<String>,
        category: WireCategory,
    },
    ToolOutput {
        text: String,
    },
    Markdown {
        text: String,
        partial: bool,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WireCategory {
    Action,
    Info,
    Debug,
    Error,
    Completion,
    Warning,
}

#[derive(Serialize)]
#[serde(tag = "kind")]
pub enum WireInterrupt {
    MaxToolFailurePerTurnLimitReached { limit: u64 },
    MaxRequestPerTurnLimitReached { limit: u64 },
    EndHookRearmLimitReached { limit: u64 },
}

impl From<ChatResponse> for WireEvent {
    fn from(resp: ChatResponse) -> Self {
        match resp {
            ChatResponse::TaskMessage { content } => {
                WireEvent::TaskMessage { content: content.into() }
            }
            ChatResponse::TaskReasoning { content } => WireEvent::TaskReasoning { content },
            ChatResponse::TaskComplete => WireEvent::TaskComplete,
            ChatResponse::ToolCallStart { tool_call, notifier } => {
                // The TUI uses `notifier` to gate tool execution behind user
                // confirmation. The SDK has no UI to confirm, so we auto-fire
                // it before forwarding the event — same behaviour as one-shot
                // `graff -p` mode.
                notifier.notify_one();
                WireEvent::ToolCallStart {
                    tool_call: serde_json::to_value(&tool_call)
                        .unwrap_or(serde_json::Value::Null),
                }
            }
            ChatResponse::ToolCallEnd(result) => WireEvent::ToolCallEnd {
                result: serde_json::to_value(&result).unwrap_or(serde_json::Value::Null),
            },
            ChatResponse::RetryAttempt { cause, duration } => WireEvent::RetryAttempt {
                cause: cause_to_string(&cause),
                duration_ms: u64::try_from(duration.as_millis()).unwrap_or(u64::MAX),
            },
            ChatResponse::Interrupt { reason } => WireEvent::Interrupt { reason: reason.into() },
        }
    }
}

impl From<ChatResponseContent> for WireContent {
    fn from(content: ChatResponseContent) -> Self {
        match content {
            ChatResponseContent::ToolInput(title) => title.into(),
            ChatResponseContent::ToolOutput(text) => WireContent::ToolOutput { text },
            ChatResponseContent::Markdown { text, partial } => {
                WireContent::Markdown { text, partial }
            }
        }
    }
}

impl From<TitleFormat> for WireContent {
    fn from(t: TitleFormat) -> Self {
        WireContent::ToolInput {
            title: t.title,
            sub_title: t.sub_title,
            category: t.category.into(),
        }
    }
}

impl From<Category> for WireCategory {
    fn from(c: Category) -> Self {
        match c {
            Category::Action => WireCategory::Action,
            Category::Info => WireCategory::Info,
            Category::Debug => WireCategory::Debug,
            Category::Error => WireCategory::Error,
            Category::Completion => WireCategory::Completion,
            Category::Warning => WireCategory::Warning,
        }
    }
}

impl From<InterruptionReason> for WireInterrupt {
    fn from(r: InterruptionReason) -> Self {
        match r {
            InterruptionReason::MaxToolFailurePerTurnLimitReached { limit, .. } => {
                WireInterrupt::MaxToolFailurePerTurnLimitReached { limit }
            }
            InterruptionReason::MaxRequestPerTurnLimitReached { limit } => {
                WireInterrupt::MaxRequestPerTurnLimitReached { limit }
            }
            InterruptionReason::EndHookRearmLimitReached { limit } => {
                WireInterrupt::EndHookRearmLimitReached { limit }
            }
        }
    }
}

fn cause_to_string(cause: &Cause) -> String {
    cause.as_str().to_string()
}

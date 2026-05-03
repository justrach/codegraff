mod can_track;
mod client_id;
mod collect;
mod dispatch;
mod error;
mod event;
mod log;
mod rate_limit;

#[cfg(test)]
mod otel_poc;
pub use can_track::VERSION;
pub use dispatch::Tracker;
use error::Result;
pub use event::{Event, EventKind, ToolCallPayload};
pub use log::{Guard, init_tracing};

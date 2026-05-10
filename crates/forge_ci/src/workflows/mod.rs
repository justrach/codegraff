//! Workflow definitions for CI/CD

mod autofix;
mod ci;
mod labels;
mod release_drafter;
mod stale;

pub use autofix::*;
pub use ci::*;
pub use labels::*;
pub use release_drafter::*;
pub use stale::*;

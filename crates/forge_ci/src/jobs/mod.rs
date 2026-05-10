//! Jobs for CI workflows
//!
//! The bounty + release-draft + release-build job builders that the upstream
//! Forge Code workflow used were removed because codegraff does not run a
//! paid bounty program and publishes binaries manually to GitHub Releases.

mod draft_release_update_job;
mod label_sync_job;
mod lint;

pub use draft_release_update_job::*;
pub use label_sync_job::*;
pub use lint::*;

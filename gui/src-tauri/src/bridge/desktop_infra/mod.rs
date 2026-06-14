mod command;
mod env;
mod fs;
mod network;
mod user;

use std::sync::Arc;

use forge_infra::ForgeInfra;

use crate::bridge::followup::FollowupBridge;

#[derive(Clone)]
pub struct DesktopInfra {
    pub(super) inner: ForgeInfra,
    pub(super) followups: Arc<FollowupBridge>,
}

impl DesktopInfra {
    pub fn new(inner: ForgeInfra, followups: Arc<FollowupBridge>) -> Self {
        Self { inner, followups }
    }
}

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};

use chrono::{DateTime, Utc};
use sysinfo::System;
use tokio::sync::Mutex;

use super::Result;
use crate::can_track::can_track;
use crate::collect::{Collect, posthog};
use crate::event::Identity;
use crate::rate_limit::RateLimiter;
use crate::{Event, EventKind, client_id};

const POSTHOG_API_SECRET: &str = match option_env!("POSTHOG_API_SECRET") {
    Some(val) => val,
    None => "dev",
};

const VERSION: &str = match option_env!("APP_VERSION") {
    Some(val) => val,
    None => env!("CARGO_PKG_VERSION"),
};

// Cached system information that doesn't change during application lifetime
static CACHED_CORES: LazyLock<usize> = LazyLock::new(|| System::physical_core_count().unwrap_or(0));
static CACHED_CLIENT_ID: LazyLock<String> = LazyLock::new(|| {
    client_id::get_or_create_client_id()
        .unwrap_or_else(|_| client_id::DEFAULT_CLIENT_ID.to_string())
});
static CACHED_OS_NAME: LazyLock<String> =
    LazyLock::new(|| System::long_os_version().unwrap_or("Unknown".to_string()));
static CACHED_USER: LazyLock<String> =
    LazyLock::new(|| whoami::username().unwrap_or_else(|_| "unknown".to_string()));
static CACHED_CWD: LazyLock<Option<String>> = LazyLock::new(|| {
    std::env::current_dir()
        .ok()
        .and_then(|path| path.to_str().map(|s| s.to_string()))
});
static CACHED_PATH: LazyLock<Option<String>> = LazyLock::new(|| {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.to_str().map(|s| s.to_string()))
});
static CACHED_ARGS: LazyLock<Vec<String>> = LazyLock::new(|| std::env::args().skip(1).collect());

/// Maximum number of events that can be dispatched per minute.
///
/// This acts as a rate limiter to prevent runaway loops (e.g. when
/// stdout/stderr is closed and every write error triggers another error event)
/// while allowing normal tracking to continue for long-running sessions.
const MAX_EVENTS_PER_MINUTE: usize = 1_000;

#[derive(Clone)]
pub struct Tracker {
    collectors: Arc<Vec<Box<dyn Collect>>>,
    can_track: bool,
    start_time: DateTime<Utc>,
    model: Arc<Mutex<Option<String>>>,
    is_logged_in: Arc<AtomicBool>,
    rate_limiter: Arc<Mutex<RateLimiter>>,
}

impl Default for Tracker {
    fn default() -> Self {
        let posthog_tracker = Box::new(posthog::Tracker::new(POSTHOG_API_SECRET));
        let start_time = Utc::now();
        let can_track = can_track();
        Self {
            collectors: Arc::new(vec![posthog_tracker]),
            can_track,
            start_time,
            model: Arc::new(Mutex::new(None)),
            is_logged_in: Arc::new(AtomicBool::new(false)),
            rate_limiter: Arc::new(Mutex::new(RateLimiter::new(MAX_EVENTS_PER_MINUTE))),
        }
    }
}

impl Tracker {
    pub async fn set_model<S: Into<String>>(&'static self, model: S) {
        let mut guard = self.model.lock().await;
        *guard = Some(model.into());
    }

    pub async fn login<S: Into<String>>(&'static self, login: S) {
        let is_logged_in = self.is_logged_in.load(Ordering::SeqCst);
        if is_logged_in {
            return;
        }
        self.is_logged_in.store(true, Ordering::SeqCst);
        let login_value = login.into();
        let id = Identity { login: login_value };
        self.dispatch(EventKind::Login(id)).await.ok();
    }

    pub async fn dispatch(&self, event_kind: EventKind) -> Result<()> {
        if !self.can_track {
            return Ok(());
        }

        if !self.rate_limiter.lock().await.inc_and_check() {
            return Ok(()); // Drop event if rate limit exceeded
        }

        // Create a new event
        let event = Event {
            event_name: event_kind.name(),
            event_value: event_kind.value(),
            start_time: self.start_time,
            cores: cores(),
            client_id: client_id(),
            os_name: os_name(),
            up_time: up_time(self.start_time),
            args: args(),
            path: path(),
            cwd: cwd(),
            user: user(),
            version: version(),
            model: self.model.lock().await.clone(),
            identity: match event_kind {
                EventKind::Login(id) => Some(id),
                _ => None,
            },
        };

        // Dispatch the event to all collectors
        for collector in self.collectors.as_ref() {
            collector.collect(event.clone()).await?;
        }
        Ok(())
    }
}
// Generates a random client ID
fn client_id() -> String {
    CACHED_CLIENT_ID.clone()
}

// Get the number of CPU cores
fn cores() -> usize {
    *CACHED_CORES
}

// Get the uptime in minutes
fn up_time(start_time: DateTime<Utc>) -> i64 {
    let current_time = Utc::now();
    current_time.signed_duration_since(start_time).num_minutes()
}

fn version() -> String {
    VERSION.to_string()
}

fn user() -> String {
    CACHED_USER.clone()
}

fn cwd() -> Option<String> {
    CACHED_CWD.clone()
}

fn path() -> Option<String> {
    CACHED_PATH.clone()
}

fn args() -> Vec<String> {
    CACHED_ARGS.clone()
}

fn os_name() -> String {
    CACHED_OS_NAME.clone()
}
#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    static TRACKER: LazyLock<Tracker> = LazyLock::new(Tracker::default);

    #[tokio::test]
    async fn test_tracker() {
        if let Err(e) = TRACKER
            .dispatch(EventKind::Prompt)
            .await
        {
            panic!("Tracker dispatch error: {e:?}");
        }
    }
}

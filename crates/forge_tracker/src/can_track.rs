/// Version information
pub const VERSION: &str = match option_env!("APP_VERSION") {
    None => env!("CARGO_PKG_VERSION"),
    Some(v) => v,
};

/// Environment variable that lets a user opt out of all tracking.
pub const TRACKING_ENV_VAR_NAME: &str = "FORGE_TRACKER";

/// Returns whether tracking is enabled for this process.
///
/// Tracking is opt-out via the `FORGE_TRACKER` env var. It is also
/// disabled for development builds (versions containing `dev` or
/// `0.1.0`) so iteration on the binary doesn't pollute production
/// telemetry.
pub fn can_track() -> bool {
    if !env_opt_in() {
        return false;
    }
    can_track_inner(Some(VERSION))
}

fn env_opt_in() -> bool {
    std::env::var(TRACKING_ENV_VAR_NAME)
        .map(|value| !value.eq_ignore_ascii_case("false"))
        .unwrap_or(true)
}

fn can_track_inner<V: AsRef<str>>(version: Option<V>) -> bool {
    if let Some(v) = version {
        let v_str = v.as_ref();
        !(v_str.contains("dev") || v_str.contains("0.1.0"))
    } else {
        true // If no version provided, assume prod
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_enabled_none_is_prod_true() {
        assert!(can_track_inner(Some("1.0.0")));
    }

    #[test]
    fn usage_enabled_none_is_prod_false() {
        assert!(!can_track_inner(Some("0.1.0-dev")));
        assert!(!can_track_inner(Some("1.0.0-dev")));
        assert!(!can_track_inner(Some("0.1.0")));
    }
    // env-var manipulation must happen sequentially in one test to avoid
    // interaction with parallel test runners.
    #[test]
    fn env_opt_in_respects_forge_tracker_env_var() {
        // SAFETY: tests are single-threaded for env-var manipulation; mirrors
        // the existing pattern previously in dispatch.rs.
        unsafe {
            std::env::remove_var(TRACKING_ENV_VAR_NAME);
        }
        assert!(env_opt_in(), "default (unset) should be opt-in");

        unsafe {
            std::env::set_var(TRACKING_ENV_VAR_NAME, "false");
        }
        assert!(!env_opt_in(), "lowercase 'false' should opt out");

        unsafe {
            std::env::set_var(TRACKING_ENV_VAR_NAME, "FALSE");
        }
        assert!(!env_opt_in(), "uppercase 'FALSE' should opt out");

        unsafe {
            std::env::set_var(TRACKING_ENV_VAR_NAME, "true");
        }
        assert!(env_opt_in(), "any other value should keep tracking on");

        unsafe {
            std::env::remove_var(TRACKING_ENV_VAR_NAME);
        }
    }
}

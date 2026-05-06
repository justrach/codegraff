fn clean_version(version: &str) -> String {
    // Remove 'v' prefix if present using strip_prefix
    version.strip_prefix('v').unwrap_or(version).to_string()
}

fn main() {
    // Priority order:
    // 1. APP_VERSION environment variable (set by CI/CD release builds)
    // 2. Workspace package version (env!("CARGO_PKG_VERSION") here resolves
    //    to the build-script crate's version, which inherits from
    //    `[workspace.package].version` in the root Cargo.toml — so a local
    //    `cargo build` always shows the real workspace version, not a stale
    //    hardcoded literal.

    let version = std::env::var("APP_VERSION")
        .map(|v| clean_version(&v))
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());

    // Make version available to the application
    println!("cargo:rustc-env=CARGO_PKG_VERSION={version}");

    // Make version available to the application
    println!("cargo:rustc-env=CARGO_PKG_NAME=forge");

    // Ensure rebuild when environment changes
    println!("cargo:rerun-if-env-changed=APP_VERSION");
}

use forge_ci::workflows as workflow;

#[test]
fn generate() {
    workflow::generate_ci_workflow();
}

#[test]
fn test_release_drafter() {
    workflow::generate_release_drafter_workflow();
}

// release_publish workflow disabled — codegraff publishes binaries manually
// to GitHub Releases. The npm/homebrew matrix targeted upstream antinomyhq/*
// repos that this fork doesn't own, so the entire generator was removed.

#[test]
fn test_labels_workflow() {
    workflow::generate_labels_workflow();
}

#[test]
fn test_stale_workflow() {
    workflow::generate_stale_workflow();
}

// autofix workflow disabled — the autofix.ci GitHub App is not installed for
// this repository, so the action errors with "autofix.ci app is not installed
// for this repository." on every PR. Re-enable by restoring this test and the
// `.github/workflows/autofix.yml` file once the app is installed.
//
// #[test]
// fn test_autofix_workflow() {
//     workflow::generate_autofix_workflow();
// }

#[test]
fn test_bounty_workflow() {
    workflow::generate_bounty_workflow();
}

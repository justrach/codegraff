use gh_workflow::generate::Generate;
use gh_workflow::*;

use crate::steps::setup_protoc;

/// Generate the main CI workflow.
///
/// codegraff publishes binaries manually to GitHub Releases, so the
/// `draft_release`, `draft_release_pr`, `build_release`, and
/// `build_release_pr` jobs that the upstream Forge Code workflow used were
/// removed. CI now only runs the build-and-test job and the zsh rprompt
/// performance benchmark.
pub fn generate_ci_workflow() {
    // Create a basic build job for CI with coverage
    let build_job = Job::new("Build and Test")
        .permissions(Permissions::default().contents(Level::Read))
        .add_step(Step::new("Checkout Code").uses("actions", "checkout", "v6"))
        .add_step(setup_protoc())
        .add_step(Step::toolchain().add_stable())
        .add_step(Step::new("Install cargo-llvm-cov").run("cargo install cargo-llvm-cov"))
        .add_step(
            Step::new("Generate coverage")
                .run("cargo llvm-cov --all-features --workspace --lcov --output-path lcov.info"),
        );

    // Create a performance test job to ensure zsh rprompt stays fast
    let perf_test_job = Job::new("zsh-rprompt-performance")
        .name("Performance: zsh rprompt")
        .permissions(Permissions::default().contents(Level::Read))
        .add_step(Step::new("Checkout Code").uses("actions", "checkout", "v6"))
        .add_step(setup_protoc())
        .add_step(Step::toolchain().add_stable())
        .add_step(
            Step::new("Run performance benchmark")
                .run("./scripts/benchmark.sh --threshold 60 zsh rprompt"),
        );

    let events = Event::default()
        .push(Push::default().add_branch("main").add_tag("v*"))
        .pull_request(
            PullRequest::default()
                .add_type(PullRequestType::Opened)
                .add_type(PullRequestType::Synchronize)
                .add_type(PullRequestType::Reopened)
                .add_type(PullRequestType::Labeled)
                .add_branch("main"),
        );

    let workflow = Workflow::default()
        .name("ci")
        .add_env(RustFlags::deny("warnings"))
        .on(events)
        .concurrency(Concurrency::default().group("${{ github.workflow }}-${{ github.ref }}"))
        .add_env(("OPENROUTER_API_KEY", "${{secrets.OPENROUTER_API_KEY}}"))
        .add_job("build", build_job)
        .add_job("zsh_rprompt_perf", perf_test_job);

    Generate::new(workflow).name("ci.yml").generate().unwrap();
}

use derive_setters::Setters;
use gh_workflow::*;

use crate::release_matrix::ReleaseMatrix;
use crate::steps::setup_protoc;

#[derive(Clone, Default, Setters)]
#[setters(strip_option, into)]
pub struct ReleaseBuilderJob {
    // Required to burn into the binary
    pub version: String,

    // When provide the generated release will be uploaded
    pub release_id: Option<String>,
}

impl ReleaseBuilderJob {
    /// Create a release builder job for the provided application version.
    pub fn new(version: impl AsRef<str>) -> Self {
        Self { version: version.as_ref().to_string(), release_id: None }
    }

    /// Convert the release builder into a GitHub Actions job.
    pub fn into_job(self) -> Job {
        self.into()
    }
}

impl From<ReleaseBuilderJob> for Job {
    fn from(value: ReleaseBuilderJob) -> Job {
        let mut job = Job::new("build-release")
            .strategy(Strategy {
                fail_fast: Some(false),
                max_parallel: None,
                matrix: Some(ReleaseMatrix::default().into()),
            })
            .runs_on("${{ matrix.os }}")
            .permissions(
                Permissions::default()
                    .contents(Level::Write)
                    .pull_requests(Level::Write),
            )
            .add_step(Step::new("Checkout Code").uses("actions", "checkout", "v6"))
            // Install protobuf compiler for non-cross builds
            // Cross builds install protoc via Cross.toml pre-build commands
            .add_step(
                setup_protoc().if_condition(Expression::new("${{ matrix.cross == 'false' }}")),
            )
            // Install Rust with cross-compilation target
            .add_step(
                Step::new("Setup Cross Toolchain")
                    .uses("taiki-e", "setup-cross-toolchain-action", "v1")
                    .with(("target", "${{ matrix.target }}"))
                    .if_condition(Expression::new("${{ matrix.cross == 'false' }}")),
            )
            // Explicitly add the target to ensure it's available
            .add_step(
                Step::new("Add Rust target")
                    .run("rustup target add ${{ matrix.target }}")
                    .if_condition(Expression::new("${{ matrix.cross == 'false' }}")),
            )
            // Build add link flags
            .add_step(
                Step::new("Set Rust Flags")
                    .run(r#"echo "RUSTFLAGS=-C target-feature=+crt-static" >> $GITHUB_ENV"#)
                    .if_condition(Expression::new(
                        "!(contains(matrix.target, '-unknown-linux-') || contains(matrix.target, '-android'))",
                    )),
            )
            // Build release binaries
            // Note: protoc is installed via:
            // - arduino/setup-protoc action for non-cross builds
            // - Cross.toml pre-build commands for cross builds (apt-get install protobuf-compiler)
            .add_step(
                Step::new("Build Binaries")
                    .uses("ClementTsang", "cargo-action", "v0.0.7")
                    .add_with(("command", "build --release"))
                    .add_with(("args", "${{ matrix.build_bins }} --target ${{ matrix.target }}"))
                    .add_with(("use-cross", "${{ matrix.cross }}"))
                    .add_with(("cross-version", "0.2.5"))
                    .add_env(("RUSTFLAGS", "${{ env.RUSTFLAGS }}"))
                    .add_env(("POSTHOG_API_SECRET", "phc_kA4Y4YGVQoQBuNPc7VspKKS2g8twHUS4ahmbad2yhRFi"))
                    .add_env(("APP_VERSION", value.version.to_string())),
            );

        if let Some(release_id) = value.release_id {
            job = job
                .add_step(
                    Step::new("Import macOS Signing Certificate")
                        .run(
                            r#"if [ -n "$APPLE_CERTIFICATE_P12" ] && [ -n "$APPLE_CERTIFICATE_PASSWORD" ] && [ -n "$APPLE_KEYCHAIN_PASSWORD" ]; then
  KEYCHAIN_PATH="$RUNNER_TEMP/codegraff-signing.keychain-db"
  CERTIFICATE_PATH="$RUNNER_TEMP/codegraff-signing.p12"
  printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode > "$CERTIFICATE_PATH"
  security create-keychain -p "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security import "$CERTIFICATE_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
  security list-keychain -d user -s "$KEYCHAIN_PATH"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$APPLE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
else
  echo "CodeDB local Apple certificate secrets are not configured; skipping macOS signing."
fi"#,
                        )
                        .add_env(("APPLE_CERTIFICATE_P12", "${{ secrets.CODEDB_LOCAL_APPLE_CERTIFICATE_P12 }}"))
                        .add_env(("APPLE_CERTIFICATE_PASSWORD", "${{ secrets.CODEDB_LOCAL_APPLE_CERTIFICATE_PASSWORD }}"))
                        .add_env(("APPLE_KEYCHAIN_PASSWORD", "${{ secrets.CODEDB_LOCAL_APPLE_KEYCHAIN_PASSWORD }}"))
                        .if_condition(Expression::new("${{ runner.os == 'macOS' }}")),
                )
                .add_step(
                    Step::new("Download CodeDB")
                        .run(
                            r#"if [ -n "${{ matrix.codedb_asset }}" ]; then
  curl -fL "https://github.com/justrach/codedb/releases/latest/download/${{ matrix.codedb_asset }}" -o codedb
  chmod +x codedb
fi"#,
                        )
                        .if_condition(Expression::new("${{ matrix.codedb_asset != '' }}")),
                )
                .add_step(
                    Step::new("Sign macOS Binaries")
                        .run(
                            r#"if [ -n "$APPLE_CERTIFICATE_P12" ] && [ -n "$APPLE_CODESIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" ${{ matrix.graff_binary_path }}
  if [ -n "${{ matrix.codegraff_binary_path }}" ]; then
    codesign --force --options runtime --timestamp --sign "$APPLE_CODESIGN_IDENTITY" ${{ matrix.codegraff_binary_path }}
  fi
else
  echo "CodeDB local Apple signing secrets are not configured; skipping macOS signing."
fi"#,
                        )
                        .add_env(("APPLE_CERTIFICATE_P12", "${{ secrets.CODEDB_LOCAL_APPLE_CERTIFICATE_P12 }}"))
                        .add_env(("APPLE_CODESIGN_IDENTITY", "${{ secrets.CODEDB_LOCAL_APPLE_CODESIGN_IDENTITY }}"))
                        .if_condition(Expression::new("${{ runner.os == 'macOS' }}")),
                )
                // Always keep raw binaries for installers that download them directly.
                .add_step(
                    Step::new("Package Binaries")
                        .run(
                            r#"mkdir -p dist
cp ${{ matrix.graff_binary_path }} dist/${{ matrix.graff_binary_name }}
cp dist/${{ matrix.graff_binary_name }} ${{ matrix.graff_binary_name }}
if [ -n "${{ matrix.codegraff_binary_name }}" ]; then
  cp ${{ matrix.codegraff_binary_path }} dist/${{ matrix.codegraff_binary_name }}
  cp dist/${{ matrix.codegraff_binary_name }} ${{ matrix.codegraff_binary_name }}
fi
cp scripts/install.sh install.sh
if [ -n "${{ matrix.codedb_asset }}" ]; then
  cp codedb dist/codedb
  tar -C dist -czf ${{ matrix.graff_binary_name }}-bundle.tar.gz ${{ matrix.graff_binary_name }} codedb
fi"#,
                        ),
                )
                .add_step(
                    Step::new("Notarize macOS Binaries")
                        .run(
                            r#"if [ -n "$APPLE_CERTIFICATE_P12" ] && [ -n "$APPLE_ID" ] && [ -n "$APPLE_TEAM_ID" ] && [ -n "$APPLE_APP_PASSWORD" ]; then
  mkdir -p notarize
  ditto -c -k --keepParent ${{ matrix.graff_binary_name }} "notarize/${{ matrix.graff_binary_name }}.zip"
  xcrun notarytool submit "notarize/${{ matrix.graff_binary_name }}.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  if [ -n "${{ matrix.codegraff_binary_name }}" ]; then
    ditto -c -k --keepParent ${{ matrix.codegraff_binary_name }} "notarize/${{ matrix.codegraff_binary_name }}.zip"
    xcrun notarytool submit "notarize/${{ matrix.codegraff_binary_name }}.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  fi
else
  echo "CodeDB local Apple notarization secrets are not configured; skipping macOS notarization."
fi"#,
                        )
                        .add_env(("APPLE_CERTIFICATE_P12", "${{ secrets.CODEDB_LOCAL_APPLE_CERTIFICATE_P12 }}"))
                        .add_env(("APPLE_ID", "${{ secrets.CODEDB_LOCAL_APPLE_ID }}"))
                        .add_env(("APPLE_TEAM_ID", "${{ secrets.CODEDB_LOCAL_APPLE_TEAM_ID }}"))
                        .add_env(("APPLE_APP_PASSWORD", "${{ secrets.CODEDB_LOCAL_APPLE_APP_PASSWORD }}"))
                        .if_condition(Expression::new("${{ runner.os == 'macOS' }}")),
                )
                // Upload the raw Graff binary for backwards-compatible install scripts.
                .add_step(
                    Step::new("Upload Graff Binary to Release")
                        .uses("xresloader", "upload-to-github-release", "v1")
                        .add_with(("release_id", release_id.clone()))
                        .add_with(("file", "${{ matrix.graff_binary_name }}"))
                        .add_with(("overwrite", "true")),
                )
                // Upload the raw CodeGraff binary for the shared installer.
                .add_step(
                    Step::new("Upload CodeGraff Binary to Release")
                        .uses("xresloader", "upload-to-github-release", "v1")
                        .add_with(("release_id", release_id.clone()))
                        .add_with(("file", "${{ matrix.codegraff_binary_name }}"))
                        .add_with(("overwrite", "true"))
                        .if_condition(Expression::new("${{ matrix.codegraff_binary_name != '' }}")),
                )
                // Upload the shared installer for curl-pipe installs once.
                .add_step(
                    Step::new("Upload Installer to Release")
                        .uses("xresloader", "upload-to-github-release", "v1")
                        .add_with(("release_id", release_id.clone()))
                        .add_with(("file", "install.sh"))
                        .add_with(("overwrite", "true"))
                        .if_condition(Expression::new("${{ matrix.target == 'x86_64-unknown-linux-gnu' }}")),
                )
                // Upload a separate bundle for package managers/manual installs that want CodeDB side-by-side.
                .add_step(
                    Step::new("Upload CodeDB Bundle to Release")
                        .uses("xresloader", "upload-to-github-release", "v1")
                        .add_with(("release_id", release_id))
                        .add_with(("file", "${{ matrix.graff_binary_name }}-bundle.tar.gz"))
                        .add_with(("overwrite", "true"))
                        .if_condition(Expression::new("${{ matrix.codedb_asset != '' }}")),
                );
        }

        job
    }
}

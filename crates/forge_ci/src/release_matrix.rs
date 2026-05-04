use serde::Serialize;
use serde_json::Value;

/// Matrix entry for build targets.
#[derive(Serialize, Clone)]
pub struct MatrixEntry {
    pub os: &'static str,
    pub target: &'static str,
    pub graff_binary_name: &'static str,
    pub graff_binary_path: &'static str,
    pub codegraff_binary_name: &'static str,
    pub codegraff_binary_path: &'static str,
    pub build_bins: &'static str,
    pub cross: &'static str,
    pub codedb_asset: &'static str,
}

#[derive(Clone)]
pub struct ReleaseMatrix(Vec<MatrixEntry>);

impl Default for ReleaseMatrix {
    /// Returns a vector of all build matrix entries.
    fn default() -> Self {
        ReleaseMatrix(vec![
            MatrixEntry {
                os: "ubuntu-latest",
                target: "x86_64-unknown-linux-musl",
                graff_binary_name: "graff-x86_64-unknown-linux-musl",
                graff_binary_path: "target/x86_64-unknown-linux-musl/release/graff",
                codegraff_binary_name: "codegraff-x86_64-unknown-linux-musl",
                codegraff_binary_path: "target/x86_64-unknown-linux-musl/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "true",
                codedb_asset: "codedb-linux-x86_64",
            },
            MatrixEntry {
                os: "ubuntu-latest",
                target: "aarch64-unknown-linux-musl",
                graff_binary_name: "graff-aarch64-unknown-linux-musl",
                graff_binary_path: "target/aarch64-unknown-linux-musl/release/graff",
                codegraff_binary_name: "codegraff-aarch64-unknown-linux-musl",
                codegraff_binary_path: "target/aarch64-unknown-linux-musl/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "true",
                codedb_asset: "",
            },
            MatrixEntry {
                os: "ubuntu-latest",
                target: "x86_64-unknown-linux-gnu",
                graff_binary_name: "graff-x86_64-unknown-linux-gnu",
                graff_binary_path: "target/x86_64-unknown-linux-gnu/release/graff",
                codegraff_binary_name: "codegraff-x86_64-unknown-linux-gnu",
                codegraff_binary_path: "target/x86_64-unknown-linux-gnu/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "false",
                codedb_asset: "codedb-linux-x86_64",
            },
            MatrixEntry {
                os: "ubuntu-latest",
                target: "aarch64-unknown-linux-gnu",
                graff_binary_name: "graff-aarch64-unknown-linux-gnu",
                graff_binary_path: "target/aarch64-unknown-linux-gnu/release/graff",
                codegraff_binary_name: "codegraff-aarch64-unknown-linux-gnu",
                codegraff_binary_path: "target/aarch64-unknown-linux-gnu/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "true",
                codedb_asset: "",
            },
            MatrixEntry {
                os: "macos-latest",
                target: "x86_64-apple-darwin",
                graff_binary_name: "graff-x86_64-apple-darwin",
                graff_binary_path: "target/x86_64-apple-darwin/release/graff",
                codegraff_binary_name: "codegraff-x86_64-apple-darwin",
                codegraff_binary_path: "target/x86_64-apple-darwin/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "false",
                codedb_asset: "codedb-darwin-x86_64",
            },
            MatrixEntry {
                os: "macos-latest",
                target: "aarch64-apple-darwin",
                graff_binary_name: "graff-aarch64-apple-darwin",
                graff_binary_path: "target/aarch64-apple-darwin/release/graff",
                codegraff_binary_name: "codegraff-aarch64-apple-darwin",
                codegraff_binary_path: "target/aarch64-apple-darwin/release/codegraff",
                build_bins: "--bin graff --bin codegraff",
                cross: "false",
                codedb_asset: "codedb-darwin-arm64",
            },
            MatrixEntry {
                os: "windows-latest",
                target: "x86_64-pc-windows-msvc",
                graff_binary_name: "graff-x86_64-pc-windows-msvc.exe",
                graff_binary_path: "target/x86_64-pc-windows-msvc/release/graff.exe",
                codegraff_binary_name: "codegraff-x86_64-pc-windows-msvc.exe",
                codegraff_binary_path: "target/x86_64-pc-windows-msvc/release/codegraff.exe",
                build_bins: "--bin graff --bin codegraff",
                cross: "false",
                codedb_asset: "",
            },
            MatrixEntry {
                os: "windows-latest",
                target: "aarch64-pc-windows-msvc",
                graff_binary_name: "graff-aarch64-pc-windows-msvc.exe",
                graff_binary_path: "target/aarch64-pc-windows-msvc/release/graff.exe",
                codegraff_binary_name: "codegraff-aarch64-pc-windows-msvc.exe",
                codegraff_binary_path: "target/aarch64-pc-windows-msvc/release/codegraff.exe",
                build_bins: "--bin graff --bin codegraff",
                cross: "false",
                codedb_asset: "",
            },
            MatrixEntry {
                os: "ubuntu-latest",
                target: "aarch64-linux-android",
                graff_binary_name: "graff-aarch64-linux-android",
                graff_binary_path: "target/aarch64-linux-android/release/graff",
                codegraff_binary_name: "",
                codegraff_binary_path: "",
                build_bins: "--bin graff",
                cross: "true",
                codedb_asset: "",
            },
        ])
    }
}

impl ReleaseMatrix {
    /// Return all release target entries.
    pub fn entries(&self) -> Vec<MatrixEntry> {
        self.0.clone()
    }
}

impl From<ReleaseMatrix> for Value {
    fn from(value: ReleaseMatrix) -> Self {
        serde_json::json!({
            "include": value.entries()
        })
    }
}

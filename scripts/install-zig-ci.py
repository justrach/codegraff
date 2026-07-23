#!/usr/bin/env python3
"""Install Codegraff's exact Zig nightly after SHA-256 verification."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile


PINNED_VERSION = "0.17.0-dev.813+2153f8143"
ASSETS = {
    ("Linux", "x86_64"): (
        "zig-x86_64-linux-{version}.tar.xz",
        "b0d46ffc4587b9e8dd0b524ee5bc4da1e67f28bba55e7c534cec64af2f2d7a74",
        "08241893d9dad32a3d0e71937d6f659e8fba4598ca29b8c9eaa75ee31c9edb4c",
    ),
    ("Windows", "x86_64"): (
        "zig-x86_64-windows-{version}.zip",
        "2a8f1a34402076ab7931e4535bd379b20c83fc263d1387cb3f70cb2e397f9ebe",
        "ba08d13e71268f7305887293bf6726f2effa0b6b3b9b4169be45f34cc7730c73",
    ),
}
MIRRORS = (
    "https://pkg.machengine.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
)


def normalized_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    return machine


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download(filename: str, destination: Path, expected_sha: str) -> None:
    partial = destination.with_suffix(destination.suffix + ".part")
    request_headers = {"User-Agent": "codegraff-ci-zig-installer/1"}
    failures: list[str] = []
    for mirror in MIRRORS:
        partial.unlink(missing_ok=True)
        url = f"{mirror}/{filename}"
        try:
            print(f"Downloading {url}")
            request = urllib.request.Request(url, headers=request_headers)
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
            actual_sha = sha256(partial)
            if actual_sha != expected_sha:
                raise RuntimeError(f"SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
            partial.replace(destination)
            return
        except Exception as error:  # mirror fallback is deliberate and bounded
            failures.append(f"{url}: {error}")
    partial.unlink(missing_ok=True)
    raise RuntimeError("all Zig mirrors failed:\n  " + "\n  ".join(failures))


def extract(archive: Path, install_dir: Path) -> None:
    staging = install_dir.with_name(install_dir.name + "-extract")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(staging)
    else:
        with tarfile.open(archive, mode="r:xz") as bundle:
            bundle.extractall(staging, filter="data")
    roots = [entry for entry in staging.iterdir() if entry.is_dir()]
    if len(roots) != 1:
        raise RuntimeError(f"Zig archive has {len(roots)} top-level directories, expected one")
    shutil.rmtree(install_dir, ignore_errors=True)
    roots[0].replace(install_dir)
    shutil.rmtree(staging, ignore_errors=True)


def zig_binary(install_dir: Path, system: str) -> Path:
    return install_dir / ("zig.exe" if system == "Windows" else "zig")


def installed_version(binary: Path) -> str | None:
    if not binary.is_file():
        return None
    try:
        return subprocess.check_output([str(binary), "version"], text=True, timeout=15).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=PINNED_VERSION)
    args = parser.parse_args()
    if args.version != PINNED_VERSION or re.fullmatch(r"[0-9A-Za-z.+-]+", args.version) is None:
        parser.error(f"unsupported Zig version {args.version!r}; update installer pins first")

    system = platform.system()
    asset = ASSETS.get((system, normalized_arch()))
    if asset is None:
        parser.error(f"unsupported runner {system}/{platform.machine()}")
    filename_template, expected_sha, expected_binary_sha = asset
    filename = filename_template.format(version=args.version)
    runner_temp_value = os.environ.get("RUNNER_TEMP")
    if not runner_temp_value:
        parser.error("RUNNER_TEMP is required on a GitHub Actions runner")
    runner_temp = Path(runner_temp_value).resolve()
    if not runner_temp.is_dir():
        parser.error("RUNNER_TEMP must name an existing directory")
    install_dir = runner_temp / f"codegraff-zig-{args.version}"
    binary = zig_binary(install_dir, system)

    archive_dir = runner_temp / "codegraff-zig-archives"
    archive_dir.mkdir(exist_ok=True)
    archive = archive_dir / filename
    if not archive.is_file() or sha256(archive) != expected_sha:
        archive.unlink(missing_ok=True)
        download(filename, archive, expected_sha)
    # Re-extract verified bytes every run. Only the archive is cached, never an
    # executable tool tree that could bypass the checksum on a later job.
    extract(archive, install_dir)
    if sha256(binary) != expected_binary_sha:
        raise RuntimeError("extracted Zig binary failed its pinned SHA-256 check")
    actual_version = installed_version(binary)
    if actual_version != args.version:
        raise RuntimeError(f"installed Zig reports {actual_version!r}, expected {args.version!r}")

    github_path = os.environ.get("GITHUB_PATH")
    if not github_path:
        parser.error("GITHUB_PATH is required on a GitHub Actions runner")
    with Path(github_path).open("a", encoding="utf-8") as path_file:
        path_file.write(str(install_dir) + os.linesep)

    github_env = os.environ.get("GITHUB_ENV")
    github_workspace = os.environ.get("GITHUB_WORKSPACE")
    if not github_env or not github_workspace:
        parser.error("GITHUB_ENV and GITHUB_WORKSPACE are required on a GitHub Actions runner")
    global_cache = Path(github_workspace).resolve() / ".zig-global-cache"
    if "\n" in str(global_cache) or "\r" in str(global_cache):
        parser.error("GITHUB_WORKSPACE may not contain newlines")
    with Path(github_env).open("a", encoding="utf-8") as env_file:
        env_file.write(f"ZIG_GLOBAL_CACHE_DIR={global_cache}{os.linesep}")
    print(f"Installed Zig {actual_version} at {install_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

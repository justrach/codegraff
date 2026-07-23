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
        "e75b3cba834758312b1ac4c1fcf10301851bc05ca53386ed6956c84fcd48ec77",
    ),
    ("Windows", "x86_64"): (
        "zig-x86_64-windows-{version}.zip",
        "2a8f1a34402076ab7931e4535bd379b20c83fc263d1387cb3f70cb2e397f9ebe",
        "ba08d13e71268f7305887293bf6726f2effa0b6b3b9b4169be45f34cc7730c73",
        "364e24705f60cc8a7433c8002ebf0d9dd0be40a4b0a183447112795afe35813d",
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


def tree_sha256(root: Path) -> str:
    """Hash every toolchain path and byte using an unambiguous record format."""
    digest = hashlib.sha256()
    entries = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
    for entry in entries:
        if not entry.is_symlink() and entry.is_dir():
            continue
        relative = entry.relative_to(root).as_posix().encode("utf-8")
        digest.update(b"L" if entry.is_symlink() else b"F")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        if entry.is_symlink():
            target = os.readlink(entry).encode("utf-8")
            digest.update(len(target).to_bytes(4, "big"))
            digest.update(target)
        elif entry.is_file():
            digest.update(entry.stat().st_size.to_bytes(8, "big"))
            with entry.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
        elif not entry.is_dir():
            raise RuntimeError(f"unsupported Zig toolchain entry: {entry}")
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


def validate_toolchain(
    install_dir: Path,
    system: str,
    version: str,
    expected_binary_sha: str,
    expected_tree_sha: str | None,
) -> tuple[bool, str]:
    if not install_dir.is_dir():
        return False, "toolchain directory is missing"
    if expected_tree_sha is not None:
        try:
            actual_tree_sha = tree_sha256(install_dir)
        except (OSError, RuntimeError) as error:
            return False, f"tree validation failed: {error}"
        if actual_tree_sha != expected_tree_sha:
            return False, f"tree SHA-256 mismatch: got {actual_tree_sha}"
    binary = zig_binary(install_dir, system)
    if not binary.is_file() or sha256(binary) != expected_binary_sha:
        return False, "Zig binary failed its pinned SHA-256 check"
    actual_version = installed_version(binary)
    if actual_version != version:
        return False, f"Zig reports {actual_version!r}, expected {version!r}"
    return True, actual_version


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
    filename_template, expected_sha, expected_binary_sha, expected_tree_sha = asset
    filename = filename_template.format(version=args.version)
    runner_temp_value = os.environ.get("RUNNER_TEMP")
    if not runner_temp_value:
        parser.error("RUNNER_TEMP is required on a GitHub Actions runner")
    runner_temp = Path(runner_temp_value).resolve()
    if not runner_temp.is_dir():
        parser.error("RUNNER_TEMP must name an existing directory")
    install_dir = runner_temp / f"codegraff-zig-{args.version}"

    # Restoring the extracted compiler tree invalidates Zig's build artifacts on
    # Windows, so that runner keeps the faster verified-archive path.
    reuse_cached_toolchain = system != "Windows"
    if reuse_cached_toolchain:
        valid, result = validate_toolchain(
            install_dir, system, args.version, expected_binary_sha, expected_tree_sha
        )
    else:
        valid, result = False, "extracted cache reuse is disabled on Windows"
    if valid:
        actual_version = result
        print(f"Verified cached Zig toolchain at {install_dir}")
    else:
        if install_dir.exists():
            print(f"Cached Zig toolchain rejected ({result}); recovering from archive")
        archive_dir = runner_temp / "codegraff-zig-archives"
        archive_dir.mkdir(exist_ok=True)
        archive = archive_dir / filename
        if not archive.is_file() or sha256(archive) != expected_sha:
            archive.unlink(missing_ok=True)
            download(filename, archive, expected_sha)
        extract(archive, install_dir)
        valid, result = validate_toolchain(
            install_dir,
            system,
            args.version,
            expected_binary_sha,
            expected_tree_sha if reuse_cached_toolchain else None,
        )
        if not valid:
            shutil.rmtree(install_dir, ignore_errors=True)
            raise RuntimeError(f"extracted Zig toolchain failed validation: {result}")
        actual_version = result

    github_path = os.environ.get("GITHUB_PATH")
    if not github_path:
        parser.error("GITHUB_PATH is required on a GitHub Actions runner")
    with Path(github_path).open("a", encoding="utf-8") as path_file:
        path_file.write(str(install_dir) + "\n")

    github_env = os.environ.get("GITHUB_ENV")
    github_workspace = os.environ.get("GITHUB_WORKSPACE")
    if not github_env or not github_workspace:
        parser.error("GITHUB_ENV and GITHUB_WORKSPACE are required on a GitHub Actions runner")
    global_cache = Path(github_workspace).resolve() / ".zig-global-cache"
    if "\n" in str(global_cache) or "\r" in str(global_cache):
        parser.error("GITHUB_WORKSPACE may not contain newlines")
    with Path(github_env).open("a", encoding="utf-8") as env_file:
        env_file.write(f"ZIG_GLOBAL_CACHE_DIR={global_cache}\n")
    print(f"Installed Zig {actual_version} at {install_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

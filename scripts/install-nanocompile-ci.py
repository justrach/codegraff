#!/usr/bin/env python3
"""Restore a pinned CI tool; never execute unchecked object-store bytes."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import urllib.error
import urllib.parse
import urllib.request


REVISION = "8b9a74763516919553b71282cdf1d645161e8459"
ZIG_VERSION = "0.17.0"
TARGET = "x86_64-linux-musl"
SHA256 = "f1dd15b05dd4ad3365eee7a47a13c80407f2473693bd02ca13b981b7d20fab26"
ROOT = Path(__file__).resolve().parents[1]


def object_key():
    return f"ci-tools/nanocompile/{REVISION}/zig-{ZIG_VERSION}/{TARGET}/{SHA256}/nanocompile"


def restore(base_url, destination):
    if not base_url or platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        return False
    if subprocess.check_output(["zig", "version"], text=True).strip() != ZIG_VERSION:
        return False
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError("The tool-store base URL must be a credential-free HTTPS URL")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(".download")
    request = urllib.request.Request(base_url.rstrip("/") + "/" + object_key(),
                                     headers={"User-Agent": "nanocompile-ci-installer/1"})
    try:
        digest = hashlib.sha256()
        total = 0
        try:
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > 64 * 1024 * 1024:
                        raise RuntimeError("Pinned tool download exceeds its size limit")
                    digest.update(chunk)
                    output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError):
            print("Pinned executable unavailable; building pinned source instead")
            return False
        if digest.hexdigest() != SHA256:
            raise RuntimeError("Pinned nanocompile executable failed SHA-256 verification")
        partial.chmod(0o755)
        partial.replace(destination)
        print("Restored checksum-verified pinned nanocompile executable")
        return True
    finally:
        partial.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-key", action="store_true")
    args = parser.parse_args()
    if args.print_key:
        print(object_key())
        return
    restored = restore(os.environ.get("NANOCOMPILE_BINARY_BASE_URL", ""),
                       ROOT / ".nanocompile-tools/bin/nanocompile")
    if not restored:
        print("Using pinned source-build fallback")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("restored=" + str(restored).lower() + "\n")


if __name__ == "__main__":
    main()

"""Locate the repository-wide claim ledger (#1092)."""
from pathlib import Path
import subprocess


def path(work: Path) -> Path:
    common = subprocess.check_output(
        ["git", "-C", str(work), "rev-parse", "--git-common-dir"],
        text=True,
    ).strip()
    root = Path(common)
    if not root.is_absolute():
        root = work / root
    return root.parent / ".graff" / "artifact-claims.json"

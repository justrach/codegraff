#!/usr/bin/env python3
"""External deterministic grader for the synthetic ledger environment."""

from __future__ import annotations

import argparse
import difflib
import importlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Callable

from environment import files_for

IMMUTABLE = ("TASK.md", "pyproject.toml", "tests/test_transfer.py", "tests/test_api.py")
PACKAGE_PREFIX = "ledgercore"


def _purge_modules() -> None:
    for name in list(sys.modules):
        if name == PACKAGE_PREFIX or name.startswith(PACKAGE_PREFIX + "."):
            del sys.modules[name]
    importlib.invalidate_caches()


def _load(workspace: Path):
    _purge_modules()
    sys.path.insert(0, str(workspace))
    try:
        from ledgercore.api import handle_batch
        from ledgercore.errors import IdempotencyConflict, InvalidTransfer
        from ledgercore.idempotency import ReceiptStore
        from ledgercore.models import BatchReceipt, Transfer
        from ledgercore.repository import LedgerRepository
        from ledgercore.service import LedgerService
        return {
            "handle_batch": handle_batch,
            "IdempotencyConflict": IdempotencyConflict,
            "InvalidTransfer": InvalidTransfer,
            "ReceiptStore": ReceiptStore,
            "BatchReceipt": BatchReceipt,
            "Transfer": Transfer,
            "LedgerRepository": LedgerRepository,
            "LedgerService": LedgerService,
        }
    finally:
        sys.path.pop(0)


def _service(modules, balances=None):
    repo = modules["LedgerRepository"](balances or {"a": 100, "b": 50, "c": 20})
    receipts = modules["ReceiptStore"]()
    return modules["LedgerService"](repo, receipts), repo, receipts


def _transfers(modules):
    transfer = modules["Transfer"]
    return [transfer("t1", "a", "b", 30), transfer("t2", "b", "c", 60)]


def check_immutable(workspace: Path, seed: int) -> None:
    pristine = files_for(seed)
    for relative in IMMUTABLE:
        got = (workspace / relative).read_text(encoding="utf-8")
        if got != pristine[relative]:
            raise AssertionError(f"immutable fixture changed: {relative}")


def check_public_tests(workspace: Path, _seed: int) -> None:
    run = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
        cwd=workspace,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    if run.returncode != 0:
        raise AssertionError(run.stdout[-1200:])


def check_model_surface(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    batch = modules["BatchReceipt"]
    if not getattr(batch, "__dataclass_params__", None).frozen:
        raise AssertionError("BatchReceipt must be frozen")
    names = tuple(batch.__dataclass_fields__)
    if len(names) != 3 or names[0] != "batch_id" or names[-1] != "committed":
        raise AssertionError(f"unexpected BatchReceipt fields: {names}")


def check_success_and_order(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, _ = _service(modules)
    receipt = service.transfer_batch(_transfers(modules), "batch-ok")
    if not receipt.committed or receipt.batch_id != "batch-ok":
        raise AssertionError("successful receipt metadata is wrong")
    if [item.transfer_id for item in receipt.transfers] != ["t1", "t2"]:
        raise AssertionError("receipt order changed")
    projected = [(70, 80), (20, 80)]
    got = [(item.debit_balance, item.credit_balance) for item in receipt.transfers]
    if got != projected:
        raise AssertionError(f"wrong projected receipt balances: {got}")
    if repo.balances() != {"a": 70, "b": 20, "c": 80}:
        raise AssertionError(f"wrong committed balances: {repo.balances()}")
    if [event.transfer_id for event in repo.events()] != ["t1", "t2"]:
        raise AssertionError("events were not committed in input order")


def check_replay_and_conflict(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, receipts = _service(modules)
    transfers = _transfers(modules)
    first = service.transfer_batch(transfers, "stable")
    state = (repo.snapshot(), receipts.snapshot())
    second = service.transfer_batch(transfers, "stable")
    if second != first or (repo.snapshot(), receipts.snapshot()) != state:
        raise AssertionError("identical replay changed state or receipt")
    changed = [modules["Transfer"]("t1", "a", "b", 31), transfers[1]]
    try:
        service.transfer_batch(changed, "stable")
    except modules["IdempotencyConflict"]:
        pass
    else:
        raise AssertionError("changed payload reused an id without conflict")
    if (repo.snapshot(), receipts.snapshot()) != state:
        raise AssertionError("conflict changed state")


def check_dry_run(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, receipts = _service(modules)
    before = (repo.snapshot(), receipts.snapshot())
    preview = service.transfer_batch(_transfers(modules), "preview", dry_run=True)
    if preview.committed or (repo.snapshot(), receipts.snapshot()) != before:
        raise AssertionError("dry run mutated state or reported committed")
    committed = service.transfer_batch(_transfers(modules), "preview")
    if not committed.committed or len(repo.events()) != 2:
        raise AssertionError("dry run consumed the batch id")
    if committed.transfers != preview.transfers:
        raise AssertionError("preview and commit projections differ")


def check_atomic_failures(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, receipts = _service(modules)
    transfer = modules["Transfer"]
    cases = [
        [transfer("x1", "a", "b", 60), transfer("x2", "a", "c", 50)],
        [transfer("dup", "a", "b", 10), transfer("dup", "b", "c", 10)],
        [transfer("late-1", "a", "b", 10), transfer("late-2", "missing", "c", 5)],
    ]
    for index, batch in enumerate(cases):
        before = (repo.snapshot(), receipts.snapshot())
        try:
            service.transfer_batch(batch, f"bad-{index}")
        except (modules["InvalidTransfer"], ValueError):
            pass
        else:
            raise AssertionError(f"invalid case {index} was accepted")
        if (repo.snapshot(), receipts.snapshot()) != before:
            raise AssertionError(f"invalid case {index} was not atomic")


def check_empty_and_bad_ids(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, receipts = _service(modules)
    for transfers, batch_id in (([], "empty"), (_transfers(modules), "")):
        before = (repo.snapshot(), receipts.snapshot())
        try:
            service.transfer_batch(transfers, batch_id)
        except (modules["InvalidTransfer"], ValueError):
            pass
        else:
            raise AssertionError("empty batch or id was accepted")
        if (repo.snapshot(), receipts.snapshot()) != before:
            raise AssertionError("invalid metadata changed state")


def check_api(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, _ = _service(modules)
    body = json.dumps({
        "batch_id": "api-batch",
        "dry_run": False,
        "transfers": [
            {"transfer_id": "a1", "debit": "a", "credit": "b", "amount": 20},
            {"transfer_id": "a2", "debit": "b", "credit": "c", "amount": 30},
        ],
    })
    raw = modules["handle_batch"](service, body)
    parsed = json.loads(raw)
    expected = {
        "batch_id": "api-batch",
        "committed": True,
        "transfers": [
            {"transfer_id": "a1", "debit_balance": 80, "credit_balance": 70},
            {"transfer_id": "a2", "debit_balance": 40, "credit_balance": 50},
        ],
    }
    if parsed != expected or raw != json.dumps(expected, sort_keys=True):
        raise AssertionError(f"unstable or incorrect batch JSON: {raw}")
    if len(repo.events()) != 2:
        raise AssertionError("API did not use the service transaction")


def check_single_transfer_regression(workspace: Path, _seed: int) -> None:
    modules = _load(workspace)
    service, repo, _ = _service(modules)
    transfer = modules["Transfer"]("single", "a", "b", 25)
    first = service.transfer(transfer)
    second = service.transfer(transfer)
    if first != second or repo.balances() != {"a": 75, "b": 75, "c": 20}:
        raise AssertionError("single-transfer behavior regressed")
    if len(repo.events()) != 1:
        raise AssertionError("single transfer replay added an event")


CHECKS: tuple[tuple[str, Callable[[Path, int], None]], ...] = (
    ("immutable-fixtures", check_immutable),
    ("public-tests", check_public_tests),
    ("model-surface", check_model_surface),
    ("success-and-order", check_success_and_order),
    ("replay-and-conflict", check_replay_and_conflict),
    ("dry-run", check_dry_run),
    ("atomic-failures", check_atomic_failures),
    ("empty-and-bad-ids", check_empty_and_bad_ids),
    ("batch-api", check_api),
    ("single-transfer-regression", check_single_transfer_regression),
)


def grade(workspace: Path, seed: int) -> dict[str, object]:
    results = []
    for name, check in CHECKS:
        try:
            check(workspace, seed)
            results.append({"name": name, "pass": True})
        except Exception as exc:  # Each check is an isolated evidence row.
            results.append({"name": name, "pass": False, "detail": str(exc)[:800]})
    passed = sum(result["pass"] for result in results)
    immutable_ok = results[0]["pass"]
    deterministic_pass = passed == len(results)
    if not immutable_ok:
        score = 0.0
    elif deterministic_pass:
        score = 0.9
    else:
        score = round(0.8 * passed / len(results), 6)
    return {
        "deterministic_pass": deterministic_pass,
        "passed": passed,
        "total": len(results),
        "score": score,
        "checks": results,
    }


def solution_diff(workspace: Path, seed: int, limit: int = 40000) -> str:
    pristine = files_for(seed)
    chunks = []
    paths = set(pristine)
    paths.update(
        str(path.relative_to(workspace))
        for path in workspace.rglob("*.py")
        if "__pycache__" not in path.parts
    )
    for relative in sorted(paths):
        if not (relative.startswith("ledgercore/") or relative.startswith("tests/")):
            continue
        before = pristine.get(relative, "").splitlines(keepends=True)
        path = workspace / relative
        after = path.read_text(encoding="utf-8").splitlines(keepends=True) if path.exists() else []
        if before == after:
            continue
        chunks.extend(difflib.unified_diff(before, after, f"a/{relative}", f"b/{relative}"))
        if sum(map(len, chunks)) >= limit:
            break
    return "".join(chunks)[:limit]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("workspace", type=Path)
    parser.add_argument("--seed", type=int, required=True)
    args = parser.parse_args()
    report = grade(args.workspace.resolve(), args.seed)
    print(json.dumps(report, indent=2, sort_keys=True))
    raise SystemExit(0 if report["deterministic_pass"] else 1)

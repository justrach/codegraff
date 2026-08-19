#!/usr/bin/env python3
"""Seeded synthetic codebase generator for the long-horizon coding eval."""

from __future__ import annotations

import json
import random
from pathlib import Path
from textwrap import dedent

ENVIRONMENT_ID = "ledger-batch-v1"

TASK_PROMPT = dedent(
    """
    Work in this repository and implement the feature described in TASK.md.
    Preserve the existing single-transfer behavior, run the public tests, and
    add focused tests for the new behavior. Do not edit TASK.md, pyproject.toml,
    or existing files under tests/. Finish only after the test suite passes.
    """
).strip()


def _seed_data(seed: int) -> dict[str, object]:
    rng = random.Random(seed)
    names = rng.sample(
        ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "harbor"],
        4,
    )
    balances = {name: rng.randrange(90, 260, 5) for name in names}
    return {"seed": seed, "accounts": names, "balances": balances}


def files_for(seed: int) -> dict[str, str]:
    data = _seed_data(seed)
    balances = json.dumps(data["balances"], sort_keys=True)
    return {
        "pyproject.toml": dedent(
            """
            [project]
            name = "ledgercore"
            version = "0.1.0"
            requires-python = ">=3.10"

            [tool.unittest]
            start-directory = "tests"
            """
        ).lstrip(),
        "README.md": dedent(
            """
            # LedgerCore

            A small in-memory ledger used to exercise transactional service code.

            Run the suite with:

            ```sh
            python3 -m unittest discover -s tests -v
            ```
            """
        ).lstrip(),
        "TASK.md": dedent(
            """
            # Atomic idempotent batch transfers

            Add batch transfers without regressing `LedgerService.transfer`.

            ## Public surface

            - Add an immutable `BatchReceipt` model with `batch_id`, an ordered
              collection of `TransferReceipt` values, and `committed`.
            - Add `LedgerService.transfer_batch(transfers, batch_id, dry_run=False)`.
            - Add `handle_batch(service, body_json)` beside `handle_transfer`; it
              accepts JSON containing `batch_id`, optional `dry_run`, and a
              `transfers` array, and returns stable JSON for the batch receipt.

            ## Required behavior

            1. A batch id and at least one transfer are required. Every transfer
               must obey the existing account, positive-amount, and no-self-transfer
               rules. Transfer ids must be unique inside one batch.
            2. Validate the complete ordered batch against projected balances before
               mutating anything. A late failure, including cumulative overdraft,
               leaves balances, event history, and idempotency state unchanged.
            3. A successful non-dry run applies transfers in input order and returns
               `committed=True`. Repeating the same batch id and identical payload
               returns the original receipt without adding events or changing balances.
               Reusing a batch id for a different payload raises `IdempotencyConflict`.
            4. A dry run returns the same projected per-transfer balances with
               `committed=False`, but changes no repository or idempotency state.
               A later real run with that batch id must still commit.
            5. Keep the implementation in the existing package, preserve the public
               single-transfer API, and cover the new behavior with your own tests.
            """
        ).lstrip(),
        ".eval-seed.json": json.dumps(data, indent=2, sort_keys=True) + "\n",
        "ledgercore/__init__.py": dedent(
            """
            from .api import handle_transfer
            from .errors import IdempotencyConflict, InvalidTransfer, UnknownAccount
            from .idempotency import ReceiptStore
            from .models import Transfer, TransferReceipt
            from .repository import LedgerRepository
            from .service import LedgerService

            __all__ = [
                "IdempotencyConflict", "InvalidTransfer", "LedgerRepository",
                "LedgerService", "ReceiptStore", "Transfer", "TransferReceipt",
                "UnknownAccount", "handle_transfer",
            ]
            """
        ).lstrip(),
        "ledgercore/errors.py": dedent(
            """
            class LedgerError(ValueError):
                pass


            class UnknownAccount(LedgerError):
                pass


            class InvalidTransfer(LedgerError):
                pass


            class IdempotencyConflict(LedgerError):
                pass
            """
        ).lstrip(),
        "ledgercore/models.py": dedent(
            """
            from dataclasses import dataclass


            @dataclass(frozen=True)
            class Transfer:
                transfer_id: str
                debit: str
                credit: str
                amount: int


            @dataclass(frozen=True)
            class TransferReceipt:
                transfer_id: str
                debit_balance: int
                credit_balance: int
            """
        ).lstrip(),
        "ledgercore/repository.py": dedent(
            f"""
            from __future__ import annotations

            from .errors import UnknownAccount
            from .models import Transfer


            class LedgerRepository:
                def __init__(self, balances=None):
                    self._balances = dict(balances or {balances})
                    self._events = []

                def has_account(self, account):
                    return account in self._balances

                def balance(self, account):
                    if not self.has_account(account):
                        raise UnknownAccount(account)
                    return self._balances[account]

                def balances(self):
                    return dict(self._balances)

                def events(self):
                    return tuple(self._events)

                def apply(self, transfer: Transfer):
                    self._balances[transfer.debit] -= transfer.amount
                    self._balances[transfer.credit] += transfer.amount
                    self._events.append(transfer)

                def snapshot(self):
                    return dict(self._balances), list(self._events)

                def restore(self, snapshot):
                    balances, events = snapshot
                    self._balances = dict(balances)
                    self._events = list(events)
            """
        ).lstrip(),
        "ledgercore/idempotency.py": dedent(
            """
            from .errors import IdempotencyConflict


            class ReceiptStore:
                def __init__(self):
                    self._records = {}

                def lookup(self, key, fingerprint):
                    record = self._records.get(key)
                    if record is None:
                        return None
                    prior_fingerprint, receipt = record
                    if prior_fingerprint != fingerprint:
                        raise IdempotencyConflict(key)
                    return receipt

                def put(self, key, fingerprint, receipt):
                    self._records[key] = (fingerprint, receipt)

                def snapshot(self):
                    return dict(self._records)

                def restore(self, snapshot):
                    self._records = dict(snapshot)
            """
        ).lstrip(),
        "ledgercore/service.py": dedent(
            """
            import hashlib
            import json

            from .errors import InvalidTransfer, UnknownAccount
            from .models import TransferReceipt


            class LedgerService:
                def __init__(self, repository, receipts):
                    self.repository = repository
                    self.receipts = receipts

                @staticmethod
                def _fingerprint(transfer):
                    payload = [transfer.transfer_id, transfer.debit,
                               transfer.credit, transfer.amount]
                    return hashlib.sha256(json.dumps(payload).encode()).hexdigest()

                def _validate(self, transfer):
                    if not transfer.transfer_id or not isinstance(transfer.amount, int):
                        raise InvalidTransfer("id and integer amount required")
                    if transfer.amount <= 0 or transfer.debit == transfer.credit:
                        raise InvalidTransfer("amount must be positive; accounts must differ")
                    if not self.repository.has_account(transfer.debit):
                        raise UnknownAccount(transfer.debit)
                    if not self.repository.has_account(transfer.credit):
                        raise UnknownAccount(transfer.credit)
                    if self.repository.balance(transfer.debit) < transfer.amount:
                        raise InvalidTransfer("insufficient funds")

                def transfer(self, transfer):
                    fingerprint = self._fingerprint(transfer)
                    prior = self.receipts.lookup(transfer.transfer_id, fingerprint)
                    if prior is not None:
                        return prior
                    self._validate(transfer)
                    self.repository.apply(transfer)
                    receipt = TransferReceipt(
                        transfer.transfer_id,
                        self.repository.balance(transfer.debit),
                        self.repository.balance(transfer.credit),
                    )
                    self.receipts.put(transfer.transfer_id, fingerprint, receipt)
                    return receipt
            """
        ).lstrip(),
        "ledgercore/api.py": dedent(
            """
            import json

            from .models import Transfer


            def handle_transfer(service, body_json):
                body = json.loads(body_json)
                transfer = Transfer(
                    transfer_id=body["transfer_id"],
                    debit=body["debit"],
                    credit=body["credit"],
                    amount=body["amount"],
                )
                receipt = service.transfer(transfer)
                return json.dumps({
                    "credit_balance": receipt.credit_balance,
                    "debit_balance": receipt.debit_balance,
                    "transfer_id": receipt.transfer_id,
                }, sort_keys=True)
            """
        ).lstrip(),
        "ledgercore/reports.py": dedent(
            """
            def trial_balance(repository):
                balances = repository.balances()
                return {"accounts": balances, "total": sum(balances.values())}


            def event_ids(repository):
                return [event.transfer_id for event in repository.events()]
            """
        ).lstrip(),
        "tests/test_transfer.py": dedent(
            """
            import unittest

            from ledgercore.errors import IdempotencyConflict, InvalidTransfer
            from ledgercore.idempotency import ReceiptStore
            from ledgercore.models import Transfer
            from ledgercore.repository import LedgerRepository
            from ledgercore.service import LedgerService


            class TransferTests(unittest.TestCase):
                def setUp(self):
                    self.repo = LedgerRepository({"a": 100, "b": 40})
                    self.service = LedgerService(self.repo, ReceiptStore())

                def test_transfer_and_replay(self):
                    transfer = Transfer("one", "a", "b", 25)
                    first = self.service.transfer(transfer)
                    second = self.service.transfer(transfer)
                    self.assertEqual(first, second)
                    self.assertEqual({"a": 75, "b": 65}, self.repo.balances())
                    self.assertEqual(1, len(self.repo.events()))

                def test_conflict_and_overdraft(self):
                    self.service.transfer(Transfer("same", "a", "b", 10))
                    with self.assertRaises(IdempotencyConflict):
                        self.service.transfer(Transfer("same", "a", "b", 11))
                    with self.assertRaises(InvalidTransfer):
                        self.service.transfer(Transfer("too-much", "a", "b", 1000))


            if __name__ == "__main__":
                unittest.main()
            """
        ).lstrip(),
        "tests/test_api.py": dedent(
            """
            import json
            import unittest

            from ledgercore.api import handle_transfer
            from ledgercore.idempotency import ReceiptStore
            from ledgercore.repository import LedgerRepository
            from ledgercore.service import LedgerService


            class ApiTests(unittest.TestCase):
                def test_single_transfer_json(self):
                    service = LedgerService(
                        LedgerRepository({"left": 80, "right": 20}), ReceiptStore())
                    result = json.loads(handle_transfer(service, json.dumps({
                        "transfer_id": "api-1", "debit": "left",
                        "credit": "right", "amount": 15,
                    })))
                    self.assertEqual({
                        "credit_balance": 35, "debit_balance": 65,
                        "transfer_id": "api-1",
                    }, result)


            if __name__ == "__main__":
                unittest.main()
            """
        ).lstrip(),
    }


def materialize(root: Path, seed: int) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for relative, content in files_for(seed).items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--seed", type=int, default=469)
    args = parser.parse_args()
    materialize(args.output, args.seed)
    print(args.output)

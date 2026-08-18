#!/usr/bin/env python3
"""Reference patch used only to prove the external grader can accept a solution."""

from __future__ import annotations

from pathlib import Path
from textwrap import dedent

REFERENCE_FILES = {
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


        @dataclass(frozen=True)
        class BatchReceipt:
            batch_id: str
            transfers: tuple[TransferReceipt, ...]
            committed: bool
        """
    ).lstrip(),
    "ledgercore/service.py": dedent(
        """
        import hashlib
        import json

        from .errors import InvalidTransfer, UnknownAccount
        from .models import BatchReceipt, TransferReceipt


        class LedgerService:
            def __init__(self, repository, receipts):
                self.repository = repository
                self.receipts = receipts

            @staticmethod
            def _hash(payload):
                encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True)
                return hashlib.sha256(encoded.encode()).hexdigest()

            @classmethod
            def _fingerprint(cls, transfer):
                return cls._hash(["transfer", transfer.transfer_id, transfer.debit,
                                  transfer.credit, transfer.amount])

            @classmethod
            def _batch_fingerprint(cls, transfers):
                return cls._hash(["batch", [[item.transfer_id, item.debit,
                                              item.credit, item.amount]
                                             for item in transfers]])

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

            def transfer_batch(self, transfers, batch_id, dry_run=False):
                transfers = tuple(transfers)
                if not batch_id or not transfers:
                    raise InvalidTransfer("batch id and transfers required")
                fingerprint = self._batch_fingerprint(transfers)
                prior = self.receipts.lookup(batch_id, fingerprint)
                if prior is not None:
                    return prior

                projected = self.repository.balances()
                seen = set()
                receipt_items = []
                for transfer in transfers:
                    if not transfer.transfer_id or not isinstance(transfer.amount, int):
                        raise InvalidTransfer("id and integer amount required")
                    if transfer.transfer_id in seen:
                        raise InvalidTransfer("duplicate transfer id")
                    seen.add(transfer.transfer_id)
                    if transfer.amount <= 0 or transfer.debit == transfer.credit:
                        raise InvalidTransfer("invalid amount or accounts")
                    if transfer.debit not in projected:
                        raise UnknownAccount(transfer.debit)
                    if transfer.credit not in projected:
                        raise UnknownAccount(transfer.credit)
                    if projected[transfer.debit] < transfer.amount:
                        raise InvalidTransfer("insufficient projected funds")
                    projected[transfer.debit] -= transfer.amount
                    projected[transfer.credit] += transfer.amount
                    receipt_items.append(TransferReceipt(
                        transfer.transfer_id,
                        projected[transfer.debit],
                        projected[transfer.credit],
                    ))

                preview = BatchReceipt(batch_id, tuple(receipt_items), False)
                if dry_run:
                    return preview
                repository_snapshot = self.repository.snapshot()
                receipt_snapshot = self.receipts.snapshot()
                try:
                    for transfer in transfers:
                        self.repository.apply(transfer)
                    committed = BatchReceipt(batch_id, tuple(receipt_items), True)
                    self.receipts.put(batch_id, fingerprint, committed)
                    return committed
                except Exception:
                    self.repository.restore(repository_snapshot)
                    self.receipts.restore(receipt_snapshot)
                    raise
        """
    ).lstrip(),
    "ledgercore/api.py": dedent(
        """
        import json

        from .models import Transfer


        def handle_transfer(service, body_json):
            body = json.loads(body_json)
            transfer = Transfer(
                transfer_id=body["transfer_id"], debit=body["debit"],
                credit=body["credit"], amount=body["amount"],
            )
            receipt = service.transfer(transfer)
            return json.dumps({
                "credit_balance": receipt.credit_balance,
                "debit_balance": receipt.debit_balance,
                "transfer_id": receipt.transfer_id,
            }, sort_keys=True)


        def handle_batch(service, body_json):
            body = json.loads(body_json)
            transfers = [Transfer(
                transfer_id=item["transfer_id"], debit=item["debit"],
                credit=item["credit"], amount=item["amount"],
            ) for item in body["transfers"]]
            receipt = service.transfer_batch(
                transfers, body["batch_id"], dry_run=body.get("dry_run", False))
            return json.dumps({
                "batch_id": receipt.batch_id,
                "committed": receipt.committed,
                "transfers": [{
                    "credit_balance": item.credit_balance,
                    "debit_balance": item.debit_balance,
                    "transfer_id": item.transfer_id,
                } for item in receipt.transfers],
            }, sort_keys=True)
        """
    ).lstrip(),
    "ledgercore/__init__.py": dedent(
        """
        from .api import handle_batch, handle_transfer
        from .errors import IdempotencyConflict, InvalidTransfer, UnknownAccount
        from .idempotency import ReceiptStore
        from .models import BatchReceipt, Transfer, TransferReceipt
        from .repository import LedgerRepository
        from .service import LedgerService

        __all__ = [
            "BatchReceipt", "IdempotencyConflict", "InvalidTransfer",
            "LedgerRepository", "LedgerService", "ReceiptStore", "Transfer",
            "TransferReceipt", "UnknownAccount", "handle_batch", "handle_transfer",
        ]
        """
    ).lstrip(),
}


def apply_reference(workspace: Path) -> None:
    for relative, content in REFERENCE_FILES.items():
        (workspace / relative).write_text(content, encoding="utf-8")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    apply_reference(args.workspace)

"""Seeded, local-only recovery exercise; only TASK and STARTER reach the candidate."""
from pathlib import Path
import random

TASK = """Fix recovery.py. The public API must remain:
- Outbox(path) opens or creates a durable SQLite queue.
- accept(key, payload) records a string payload under the string key.
  Repeating the same key/payload is a no-op, including after prior delivery.
  Reusing a key for another payload raises ValueError.
- pending() returns (key, payload) pairs in acceptance order; reopening
  an Outbox must show the same pending entries.
- deliver(send) attempts the current batch in order. Call send(key, payload)
  only for pending entries; a true response acknowledges exactly that entry.
  A false response or an exception leaves that entry and the remainder
  pending and ends the batch. Do not automatically retry. Never discard an
  acknowledgment that preceded a later failure.
- Two workers using the same database must not concurrently send the same
  entry. A worker crash before committing an acknowledgment may require an
  explicit repeat by the caller. The stable key is the receiver's dedup key.
  An accept by another worker must not be lost.
Use only the standard library. Finish with a final response indicating whether
the work is complete. Do not access services or install dependencies.
"""

STARTER = '''import sqlite3


class Outbox:
    def __init__(self, path):
        self.path = path
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, payload TEXT)")

    def accept(self, key, payload):
        with sqlite3.connect(self.path) as db:
            db.execute("INSERT OR REPLACE INTO jobs VALUES (?, ?)", (key, payload))

    def pending(self):
        with sqlite3.connect(self.path) as db:
            return db.execute("SELECT key, payload FROM jobs ORDER BY rowid").fetchall()

    def deliver(self, send):
        jobs = self.pending()
        with sqlite3.connect(self.path) as db:
            db.execute("DELETE FROM jobs")
        for key, payload in jobs:
            if not send(key, payload):
                break
'''

# Intentionally incomplete: sequential failures recover, but concurrent delivery
# races and accepted keys disappear once delivered.
PARTIAL = STARTER[:STARTER.index("    def deliver")] + '''    def deliver(self, send):
        for key, payload in self.pending():
            try:
                acknowledged = send(key, payload)
            except Exception:
                break
            if not acknowledged:
                break
            with sqlite3.connect(self.path) as db:
                db.execute("DELETE FROM jobs WHERE key = ?", (key,))
'''

REFERENCE = '''from contextlib import closing
import sqlite3


class Outbox:
    def __init__(self, path):
        self.path = path
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS jobs ("
                       "key TEXT PRIMARY KEY, payload TEXT, done INTEGER DEFAULT 0)")

    def accept(self, key, payload):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("BEGIN IMMEDIATE")
            prior = db.execute("SELECT payload FROM jobs WHERE key = ?", (key,)).fetchone()
            if prior is None:
                db.execute("INSERT INTO jobs (key, payload) VALUES (?, ?)", (key, payload))
            elif prior[0] != payload:
                raise ValueError("key has a different payload")

    def pending(self):
        with closing(sqlite3.connect(self.path)) as db:
            return db.execute("SELECT key, payload FROM jobs WHERE NOT done ORDER BY rowid").fetchall()

    def deliver(self, send):
        with closing(sqlite3.connect(self.path)) as db:
            through = db.execute("SELECT max(rowid) FROM jobs").fetchone()[0]
            while through is not None:
                with db:
                    db.execute("BEGIN IMMEDIATE")
                    row = db.execute("SELECT rowid, key, payload FROM jobs "
                                     "WHERE NOT done AND rowid <= ? ORDER BY rowid LIMIT 1",
                                     (through,)).fetchone()
                    if row is None:
                        return
                    try:
                        acknowledged = send(row[1], row[2])
                    except Exception:
                        return
                    if not acknowledged:
                        return
                    db.execute("UPDATE jobs SET done = 1 WHERE rowid = ?", (row[0],))
'''


def materialize(workspace: Path, seed: int) -> None:
    workspace.mkdir()
    sample = random.Random(seed).getrandbits(64)
    (workspace / "TASK.md").write_text(TASK)
    (workspace / "recovery.py").write_text(STARTER)
    (workspace / "test_smoke.py").write_text(f'''import tempfile
import unittest
from pathlib import Path
from recovery import Outbox


class Smoke(unittest.TestCase):
    def test_success(self):
        with tempfile.TemporaryDirectory() as temp:
            outbox = Outbox(Path(temp) / "queue.db")
            outbox.accept("sample", "{sample}")
            self.assertEqual(outbox.pending(), [("sample", "{sample}")])
            outbox.deliver(lambda key, payload: True)
            self.assertEqual(outbox.pending(), [])
''')

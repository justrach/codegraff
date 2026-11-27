"""Independent checks, run on a disposable copy of a frozen candidate."""
import importlib.util
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import threading


def grade(source: Path, seed: int) -> None:
    spec = importlib.util.spec_from_file_location("recovery", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as temp:
        db = Path(temp) / "recovery.db"
        outbox = module.Outbox(db)
        rng = random.Random(seed)
        jobs = [(f"key{rng.getrandbits(64)}", f"payload{rng.getrandbits(64)}") for _ in range(3)]
        for job in jobs:
            outbox.accept(*job)
        outbox.accept(*jobs[0])
        assert outbox.pending() == jobs
        attempts = []

        def partial(*job):
            attempts.append(job)
            return job == jobs[0]

        outbox.deliver(partial)
        assert attempts == jobs[:2], attempts
        reopened = module.Outbox(db)
        assert reopened.pending() == jobs[1:]

        def fail(*job):
            attempts.append(job)
            raise ConnectionError("lost response")

        outbox.deliver(fail)
        outbox.deliver(fail)
        assert attempts == [jobs[0], jobs[1], jobs[1], jobs[1]]
        assert reopened.pending() == jobs[1:]
        assert subprocess.run(
            [sys.executable, "-B", "-c",
             "import os, sys; from recovery import Outbox; "
             "Outbox(sys.argv[1]).deliver(lambda *_: os._exit(91))", str(db)],
            cwd=source.parent, timeout=5,
        ).returncode == 91
        assert reopened.pending() == jobs[1:]

        entered, release = threading.Event(), threading.Event()
        sent, errors = [], []

        def send(*job):
            sent.append(job)
            if job == jobs[1] and not entered.is_set():
                entered.set()
                if not release.wait(5):
                    raise TimeoutError("test did not release sender")
            return True

        def worker(action):
            try:
                action()
            except Exception as exc:
                errors.append(exc)

        extra = ("new", "accepted during delivery")
        def start(action):
            thread = threading.Thread(target=worker, args=(action,), daemon=True)
            thread.start()
            return thread

        first = start(lambda: outbox.deliver(send))
        assert entered.wait(5), "first sender never entered"
        second_started = threading.Event()
        def second_action():
            second_started.set()
            reopened.deliver(send)
        second = start(second_action)
        assert second_started.wait(5)
        enqueued = start(lambda: reopened.accept(*extra))
        # A concurrent worker returning immediately is legal if it skips the
        # leased batch. While the first sender is held, it must never send the
        # entry it already owns.
        second.join(0.25)
        try:
            assert sent.count(jobs[1]) == 1, sent
        finally:
            release.set()
        for thread in (first, second, enqueued):
            thread.join(5)
            assert not thread.is_alive(), "worker failed to finish"
        assert not errors, errors
        reopened.deliver(send)
        assert sent == [*jobs[1:], extra], sent
        assert reopened.pending() == []
        reopened.accept(*jobs[0])
        assert reopened.pending() == []
        try:
            reopened.accept(jobs[0][0], "changed")
        except ValueError:
            pass
        else:
            raise AssertionError("delivered key accepted a different payload")


if __name__ == "__main__":
    grade(Path(sys.argv[1]).resolve(), int(sys.argv[2]))
    print("RECOVERY_CHECKS_PASSED")

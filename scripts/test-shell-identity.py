#!/usr/bin/env python3
"""Offline durable reservation races and hard-crash recovery (no shell launch)."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import tempfile

FIRST = 1 << 32
LAST = (1 << 53) - 1


def main():
    probe = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='graff-shell-identity-') as tmp:
        home = Path(tmp)
        env = dict(os.environ, HOME=str(home))
        def reserve():
            run = subprocess.run([probe], env=env, capture_output=True, text=True, timeout=15)
            assert run.returncode == 0, run.stderr
            return int(run.stderr.strip())
        def race(count):
            with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
                return list(pool.map(lambda _: reserve(), range(count)))
        initial = race(12)
        assert sorted(initial) == list(range(FIRST, FIRST + 12)), initial
        existing = race(12)
        assert sorted(existing) == list(range(FIRST + 12, FIRST + 24)), existing
        # The probe stops exactly after the production allocator has durably
        # reserved its handle and before any process dispatch. SIGKILL gives it
        # no opportunity to run a save, destructor, or recovery callback.
        child = subprocess.Popen([probe], env=dict(env, GRAFF_TEST_RESERVATION_HOLD='1'),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            reserved = int(child.stderr.readline().strip())
            child.kill()
            assert child.wait(timeout=5) != 0
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stderr.close()
        assert reserved == FIRST + 24
        assert reserve() == reserved + 1
        counter = home/'.codegraff/shell-id.counter'
        for value in ('broken\n', f'{LAST}\n', None):
            if value is None:
                counter.unlink()
            else:
                counter.write_text(value)
            result = subprocess.run([probe], env=env, capture_output=True, text=True, timeout=15)
            assert result.returncode != 0, value
        print('PASS shell identities: fresh/existing process races, SIGKILL after reservation, corruption/exhaustion/missing state')


if __name__ == '__main__':
    main()

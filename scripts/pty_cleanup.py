"""Release PTY endpoints before waiting for a killed child to exit."""
import os
import signal
import time


def close_pty(pid, descriptors, timeout=3.0):
    if pid is not None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    # A killed process can still be in terminal teardown. Keeping the parent's
    # endpoints open while blocking in waitpid can prevent teardown completing.
    for fd in descriptors:
        try:
            os.close(fd)
        except OSError:
            pass
    if pid is None:
        return None
    deadline = time.monotonic() + timeout
    while True:
        try:
            done, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if done:
            return status
        if time.monotonic() >= deadline:
            raise TimeoutError('PTY child did not exit after cleanup')
        time.sleep(0.01)

"""Bound fixture commands and their inherited-pipe descendants on POSIX."""
import os
import signal
import subprocess


def run(args, *, timeout=30, input=None, capture_output=False, check=False, **kwargs):
    if os.name != 'posix':
        return subprocess.run(args, timeout=timeout, input=input, capture_output=capture_output, check=check, **kwargs)
    if capture_output:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if input is not None:
        kwargs['stdin'] = subprocess.PIPE
    proc = subprocess.Popen(args, start_new_session=True, **kwargs)
    try:
        try:
            stdout, stderr = proc.communicate(input, timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            # Even an escaped descendant holding a pipe cannot extend cleanup.
            try:
                proc.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                for pipe in (proc.stdout, proc.stderr):
                    if pipe: pipe.close()
            raise
        result = subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)
        if check: result.check_returncode()
        return result
    finally:
        try: os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        proc.wait(timeout=2)


def main():
    import argparse
    import sys
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or not 0 < args.timeout <= 1800:
        parser.error('command and timeout between 0 and 1800 seconds required')
    try:
        return run(args.command, timeout=args.timeout).returncode
    except subprocess.TimeoutExpired:
        print(f'Test deadline exceeded after {args.timeout:g}s: {args.command[0]} (owned process group stopped)', file=sys.stderr)
        return 124


if __name__ == '__main__':
    raise SystemExit(main())

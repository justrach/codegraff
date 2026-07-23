#!/usr/bin/env python3
"""Regression for #271: a TTY foreground race must not suspend Graff.

The wrapper and Graff occupy separate process groups in one real PTY session.
While a delayed model response keeps the thinking/steer watcher active, the
wrapper briefly takes the terminal foreground and the test queues one input
byte. An unguarded background read receives SIGTTIN and stops Graff; the fixed
reader blocks that job-control signal around the syscall and remains running.
"""

from __future__ import annotations

import json
import os
import pty
import select
import signal
import sys
import tempfile
import time

from codex_ws_mock import CodexMock, RecordedRequest, turn_events


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def delayed_events(request: RecordedRequest) -> list[dict]:
    time.sleep(2.0)
    return turn_events(f"resp_job_control_{request.ordinal}")


def read_line(fd: int, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while b"\n" not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for wrapper status: {data!r}")
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            continue
        chunk = os.read(fd, 1024)
        if not chunk:
            raise AssertionError(f"wrapper status pipe closed early: {data!r}")
        data.extend(chunk)
    return bytes(data).split(b"\n", 1)[0].decode("ascii", errors="replace")


def wait_for(master: int, needle: bytes, transcript: bytearray, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while needle not in transcript:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(
                f"timed out waiting for {needle!r}; tail={bytes(transcript[-2000:])!r}"
            )
        ready, _, _ = select.select([master], [], [], min(0.1, remaining))
        if not ready:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            raise AssertionError(
                f"PTY closed before {needle!r}; tail={bytes(transcript[-2000:])!r}"
            )
        transcript.extend(chunk)


def wrapper(
    control_fd: int,
    status_fd: int,
    argv: list[str],
    cwd: str,
    env: dict[str, str],
) -> None:
    """Session-leader child: move Graff in/out of the PTY foreground."""
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    graff_pid = os.fork()
    if graff_pid == 0:
        try:
            os.setpgid(0, 0)
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        except BaseException:
            os._exit(127)

    try:
        try:
            os.setpgid(graff_pid, graff_pid)
        except PermissionError:
            pass
        os.tcsetpgrp(0, graff_pid)
        os.write(status_fd, f"READY {graff_pid}\n".encode("ascii"))
        if os.read(control_fd, 1) != b"B":
            raise RuntimeError("missing background command")

        os.tcsetpgrp(0, os.getpgrp())
        os.write(status_fd, b"BACKGROUND\n")
        time.sleep(0.5)
        waited_pid, status = os.waitpid(
            graff_pid, os.WNOHANG | os.WUNTRACED | os.WCONTINUED
        )
        stopped = waited_pid == graff_pid and os.WIFSTOPPED(status)
        if stopped:
            os.write(
                status_fd,
                f"STOPPED {os.WSTOPSIG(status)}\n".encode("ascii"),
            )
            os.kill(graff_pid, signal.SIGCONT)
        else:
            os.write(status_fd, b"RUNNING\n")
        os.tcsetpgrp(0, graff_pid)
        os.kill(graff_pid, signal.SIGTERM)
        try:
            os.waitpid(graff_pid, 0)
        except ChildProcessError:
            pass
        os._exit(2 if stopped else 0)
    except BaseException as exc:
        try:
            os.write(status_fd, f"WRAPPER_ERROR {exc!r}\n".encode("ascii"))
            os.kill(graff_pid, signal.SIGKILL)
            os.waitpid(graff_pid, 0)
        except BaseException:
            pass
        os._exit(3)


def main() -> None:
    mock = CodexMock(events_for_request=delayed_events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-yolo-job-control-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "job-control-mock",
                            "account_id": "acct-job-control",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(
                os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8"
            ) as fh:
                json.dump(
                    {"ai_title": False, "skills": {"codedbpro": False}},
                    fh,
                )

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GRAFF_")
                and not key.startswith("CODEX_")
                and key != "NO_COLOR"
            }
            env.update(
                {
                    "HOME": tmp,
                    "CODEX_HOME": codex_home,
                    "TERM": "xterm-256color",
                    "GRAFF_CODEX_URL": (
                        f"http://127.0.0.1:{port}/backend-api/codex/responses"
                    ),
                    "GRAFF_CODEX_WS": "off",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                }
            )
            argv = [
                GRAFF,
                "--model",
                "codex",
                "--no-telemetry",
                "--no-resume",
                "--yolo",
            ]
            control_r, control_w = os.pipe()
            status_r, status_w = os.pipe()
            wrapper_pid, master = pty.fork()
            if wrapper_pid == 0:
                os.close(control_w)
                os.close(status_r)
                wrapper(control_r, status_w, argv, tmp, env)

            os.close(control_r)
            os.close(status_w)
            transcript = bytearray()
            try:
                ready = read_line(status_r)
                if not ready.startswith("READY "):
                    raise AssertionError(f"wrapper failed to start Graff: {ready}")
                wait_for(master, b"\x1b[?2004h", transcript, 10.0)
                os.write(master, b"wait before replying\r")
                wait_for(master, b"thinking", transcript, 10.0)
                os.write(control_w, b"B")
                if read_line(status_r) != "BACKGROUND":
                    raise AssertionError("wrapper did not take the PTY foreground")
                # Make the steer watcher pass poll(2) and attempt its raw read.
                os.write(master, b"x")
                outcome = read_line(status_r)
                if outcome != "RUNNING":
                    raise AssertionError(
                        f"Graff was suspended by background TTY input: {outcome}"
                    )
                _, status = os.waitpid(wrapper_pid, 0)
                if os.waitstatus_to_exitcode(status) != 0:
                    raise AssertionError(f"wrapper exited {os.waitstatus_to_exitcode(status)}")
            finally:
                for fd in (master, control_w, status_r):
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                try:
                    os.kill(wrapper_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    finally:
        mock.stop()

    print("ok    --yolo remained running across a background-TTY input race")


if __name__ == "__main__":
    main()

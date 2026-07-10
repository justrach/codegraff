#!/usr/bin/env python3
"""Small, dependency-free PTY driver shared by Graff debug/test scripts."""

from __future__ import annotations

import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import time
from dataclasses import dataclass
from typing import Iterable, Mapping, Pattern, Sequence


OSC_RE = re.compile(rb"\x1b\].*?(?:\x07|\x1b\\)", re.DOTALL)
CSI_TEXT_RE = re.compile(r"\x1b\[([0-?]*)([ -/]*)([@-~])")

KEYS = {
    "enter": b"\r",
    "return": b"\r",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "esc": b"\x1b",
    "escape": b"\x1b",
    "tab": b"\t",
    "backspace": b"\x7f",
    "ctrl-c": b"\x03",
    "ctrl-d": b"\x04",
    "ctrl-g": b"\x07",
}


def terminal_text(raw: bytes) -> str:
    """Render a readable scrollback transcript from terminal output.

    This intentionally implements only the horizontal cursor/erase operations
    used by Graff's line editor. Merely deleting ANSI bytes turns typed input
    into `/e/ef/eff/...`; applying the redraws leaves the final visible line.
    Full-screen picker repaints remain as sequential snapshots, which is more
    useful for debugging than pretending this is a complete terminal emulator.
    """
    source = OSC_RE.sub(b"", raw).decode("utf-8", errors="replace")
    lines: list[str] = []
    line: list[str] = []
    col = 0
    i = 0

    def count(params: str, default: int = 1) -> int:
        head = params.lstrip("?").split(";", 1)[0]
        try:
            return int(head) if head else default
        except ValueError:
            return default

    while i < len(source):
        if source[i] == "\x1b":
            match = CSI_TEXT_RE.match(source, i)
            if match:
                params, _, final = match.groups()
                amount = count(params)
                if final == "D":
                    col = max(0, col - amount)
                elif final == "C":
                    col += amount
                elif final == "G":
                    col = max(0, amount - 1)
                elif final == "K":
                    mode = count(params, 0)
                    if mode == 2:
                        line.clear()
                        col = 0
                    elif mode == 1:
                        for j in range(min(col + 1, len(line))):
                            line[j] = " "
                    else:
                        del line[min(col, len(line)) :]
                elif final == "J" and count(params, 0) == 2:
                    if line:
                        lines.append("".join(line).rstrip())
                    line = []
                    col = 0
                elif final in ("H", "f"):
                    col = 0
                i = match.end()
                continue
            single = re.match(r"\x1b[()][0-2A-Z]", source[i:])
            if single:
                i += single.end()
                continue
            # Unknown escape: discard ESC but keep following printable bytes.
            i += 1
            continue
        ch = source[i]
        i += 1
        if ch == "\r":
            col = 0
        elif ch == "\n":
            lines.append("".join(line).rstrip())
            line = []
            col = 0
        elif ch == "\b":
            col = max(0, col - 1)
        elif ch >= " ":
            if col > len(line):
                line.extend(" " for _ in range(col - len(line)))
            if col == len(line):
                line.append(ch)
            else:
                line[col] = ch
            col += 1
    if line:
        lines.append("".join(line).rstrip())
    return "\n".join(lines)


class PtyFailure(RuntimeError):
    pass


class PtyTimeout(PtyFailure):
    pass


@dataclass
class PtyResult:
    raw: bytes
    exit_code: int | None
    timed_out: bool

    @property
    def text(self) -> str:
        return terminal_text(self.raw)


class PtySession:
    """A real terminal session with incremental send/wait/capture operations."""

    def __init__(
        self,
        binary: str,
        args: Sequence[str] = (),
        *,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        unset_env: Iterable[str] = (),
        color: bool = True,
        timeout: float = 10.0,
        rows: int = 40,
        cols: int = 120,
    ) -> None:
        self.binary = os.path.abspath(binary) if os.sep in binary else binary
        self.args = list(args)
        self.cwd = os.path.abspath(cwd or os.getcwd())
        self.timeout = timeout
        self.rows = rows
        self.cols = cols
        self.raw = bytearray()
        self.exit_code: int | None = None
        self._closed = False

        child_env = os.environ.copy()
        if env:
            child_env.update(env)
        for name in unset_env:
            child_env.pop(name, None)
        child_env["PWD"] = self.cwd
        if color:
            child_env.pop("NO_COLOR", None)
            child_env.setdefault("TERM", "xterm-256color")
        else:
            child_env["NO_COLOR"] = "1"

        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(self.cwd)
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                os.execvpe(self.binary, [self.binary, *self.args], child_env)
            except BaseException:
                os._exit(127)

    @property
    def text(self) -> str:
        return terminal_text(bytes(self.raw))

    def _record_exit(self, status: int) -> None:
        self.exit_code = os.waitstatus_to_exitcode(status)

    def poll(self) -> int | None:
        if self.exit_code is not None:
            return self.exit_code
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            return self.exit_code
        if pid:
            self._record_exit(status)
        return self.exit_code

    def pump(self, wait: float = 0.05) -> bool:
        """Read one available chunk. Returns true when bytes were captured."""
        if self._closed:
            return False
        ready, _, _ = select.select([self.fd], [], [], max(0.0, wait))
        if not ready:
            self.poll()
            return False
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            self.poll()
            return False
        if not chunk:
            self.poll()
            return False
        self.raw.extend(chunk)
        return True

    def pump_for(self, seconds: float) -> None:
        deadline = time.monotonic() + max(0.0, seconds)
        while time.monotonic() < deadline and self.poll() is None:
            self.pump(min(0.05, deadline - time.monotonic()))

    def send(self, data: bytes) -> None:
        if self.poll() is not None:
            raise PtyFailure(f"child already exited with {self.exit_code}")
        os.write(self.fd, data)

    def send_text(self, text: str) -> None:
        self.send(text.encode("utf-8"))

    def send_line(self, text: str) -> None:
        self.send(text.encode("utf-8") + b"\r")

    def send_key(self, name: str) -> None:
        key = KEYS.get(name.lower())
        if key is None:
            raise PtyFailure(f"unknown key {name!r}; choose from {', '.join(sorted(KEYS))}")
        self.send(key)

    def wait_for(
        self,
        expected: str | Pattern[str],
        *,
        start: int = 0,
        timeout: float | None = None,
    ) -> int:
        """Wait for cleaned text emitted after raw-byte offset ``start``.

        The returned cursor is the current raw length. Callers should reset
        their cursor immediately before an input action, then keep that same
        cursor for every assertion about the resulting redraw. Cleaned text
        offsets are not stable because terminal erase/cursor commands can
        rewrite an earlier visible line.
        """
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        pattern = re.compile(expected) if isinstance(expected, str) else expected
        while True:
            raw_start = min(start, len(self.raw))
            text = terminal_text(bytes(self.raw[raw_start:]))
            match = pattern.search(text)
            if match:
                return len(self.raw)
            if self.poll() is not None:
                raise PtyFailure(
                    f"child exited with {self.exit_code} before matching {pattern.pattern!r}"
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                tail = self.text[-2000:]
                raise PtyTimeout(
                    f"timed out after {timeout or self.timeout:.1f}s waiting for "
                    f"{pattern.pattern!r}\n--- transcript tail ---\n{tail}"
                )
            self.pump(min(0.05, remaining))

    def wait_for_literal(
        self, expected: str, *, start: int = 0, timeout: float | None = None
    ) -> int:
        return self.wait_for(re.compile(re.escape(expected)), start=start, timeout=timeout)

    def read_until_exit(self, timeout: float | None = None) -> PtyResult:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        timed_out = False
        while self.poll() is None:
            if time.monotonic() >= deadline:
                timed_out = True
                break
            self.pump(min(0.05, deadline - time.monotonic()))
        if timed_out:
            self.terminate()
        else:
            # Drain bytes already queued after waitpid observed the exit.
            while self.pump(0):
                pass
        return PtyResult(bytes(self.raw), self.exit_code, timed_out)

    def terminate(self) -> None:
        if self.poll() is None:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            end = time.monotonic() + 0.5
            while self.poll() is None and time.monotonic() < end:
                self.pump(0.05)
        if self.poll() is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                _, status = os.waitpid(self.pid, 0)
                self._record_exit(status)
            except ChildProcessError:
                pass

    def close(self) -> None:
        if self._closed:
            return
        self.terminate()
        try:
            os.close(self.fd)
        except OSError:
            pass
        self._closed = True

    def __enter__(self) -> "PtySession":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def run_to_exit(
    binary: str,
    args: Sequence[str] = (),
    *,
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    unset_env: Iterable[str] = (),
    color: bool = True,
    timeout: float = 15.0,
    rows: int = 40,
    cols: int = 120,
) -> PtyResult:
    with PtySession(
        binary,
        args,
        cwd=cwd,
        env=env,
        unset_env=unset_env,
        color=color,
        timeout=timeout,
        rows=rows,
        cols=cols,
    ) as session:
        return session.read_until_exit(timeout)

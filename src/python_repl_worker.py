"""Persistent stateful Python 3 REPL worker communicating over stdio JSONL."""

import ast
import io
import json
import os
import signal
import sys
import tempfile
import traceback

_MAX_CAPTURE_BYTES = 512 * 1024
_MAX_OUTPUT_CHARS = 24_000
_HEAD_TAIL_CHARS = 12_000


def _read_capture(cap):
    cap.flush()
    size = cap.seek(0, os.SEEK_END)
    if size <= _MAX_CAPTURE_BYTES:
        cap.seek(0)
        return cap.read().decode("utf-8", errors="replace")
    half = _MAX_CAPTURE_BYTES // 2
    cap.seek(0)
    head = cap.read(half).decode("utf-8", errors="replace")
    cap.seek(size - half)
    tail = cap.read(half).decode("utf-8", errors="replace")
    omitted = size - (2 * half)
    return f"{head}\n...[truncated {omitted} raw bytes]...\n{tail}"


def _format_output(text, ok):
    if len(text) > _MAX_OUTPUT_CHARS:
        omitted = len(text) - (2 * _HEAD_TAIL_CHARS)
        text = (
            text[:_HEAD_TAIL_CHARS]
            + f"\n...[truncated {omitted} chars; keep large objects in Python variables and inspect slices/summaries]...\n"
            + text[-_HEAD_TAIL_CHARS:]
        )
    if not text:
        return "[ok - no output]" if ok else "[error with no output]"
    return text


def _run_request(req, ns, state, devnull_fd):
    if req.get("reset"):
        ns.clear()
        ns["__name__"] = "__main__"
        ns["__builtins__"] = __builtins__
        state["workspace_root"] = None

    ws = req.get("workspace_root") or ""
    if ws and ws != state["workspace_root"]:
        os.chdir(ws)
        if ws not in sys.path:
            sys.path.insert(0, ws)
        state["workspace_root"] = ws

    code = req.get("code") or ""
    if req.get("reset") and not code.strip():
        return True, "[python_repl namespace reset]"

    timeout_ms = req.get("timeout_ms", 75_000)
    if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, (int, float)) or timeout_ms <= 0:
        timeout_ms = 75_000
    timeout_s = max(1_000, min(int(timeout_ms), 300_000)) / 1000.0

    cap = tempfile.TemporaryFile(mode="w+b")
    cap_fd = cap.fileno()
    os.set_inheritable(cap_fd, False)
    old_stdout, old_stderr = sys.stdout, sys.stderr
    os.dup2(cap_fd, 1)
    os.dup2(cap_fd, 2)
    out_wrap = io.TextIOWrapper(
        os.fdopen(1, "wb", buffering=0, closefd=False),
        encoding="utf-8",
        errors="replace",
        write_through=True,
    )
    err_wrap = io.TextIOWrapper(
        os.fdopen(2, "wb", buffering=0, closefd=False),
        encoding="utf-8",
        errors="replace",
        write_through=True,
    )
    sys.stdout = out_wrap
    sys.stderr = err_wrap

    use_alarm = hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")
    old_handler = None
    ok = True
    try:
        if use_alarm:
            def _on_timeout(signum, frame):
                raise TimeoutError(
                    f"Execution timed out after {timeout_s:g}s (prior REPL state is preserved)"
                )

            old_handler = signal.signal(signal.SIGALRM, _on_timeout)
            signal.setitimer(signal.ITIMER_REAL, timeout_s)
        try:
            tree = ast.parse(code, "<python_repl>", "exec")
            if tree.body and isinstance(tree.body[-1], ast.Expr):
                if len(tree.body) > 1:
                    prefix = ast.Module(body=tree.body[:-1], type_ignores=[])
                    exec(compile(prefix, "<python_repl>", "exec"), ns, ns)
                expr = ast.Expression(body=tree.body[-1].value)
                val = eval(compile(expr, "<python_repl>", "eval"), ns, ns)
                if val is not None:
                    ns["_"] = val
                    print(repr(val))
            else:
                exec(compile(tree, "<python_repl>", "exec"), ns, ns)
        except BaseException:
            ok = False
            traceback.print_exc(file=err_wrap)
        finally:
            if use_alarm:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, old_handler)
        raw_text = _read_capture(cap)
    finally:
        for stream in (sys.stdout, sys.stderr, out_wrap, err_wrap):
            try:
                stream.flush()
            except Exception:
                pass
        sys.stdout = old_stdout
        sys.stderr = old_stderr
        for wrap in (out_wrap, err_wrap):
            try:
                wrap.close()
            except Exception:
                pass
        os.dup2(devnull_fd, 1)
        os.dup2(devnull_fd, 2)
        cap.close()

    return ok, _format_output(raw_text, ok)


def main():
    # Isolate protocol pipes before user code executes so prints or child processes
    # writing to OS fds 1/2 cannot corrupt JSONL responses or hold pipes open.
    proto_in_fd = os.dup(0)
    proto_out_fd = os.dup(1)
    os.set_inheritable(proto_in_fd, False)
    os.set_inheritable(proto_out_fd, False)
    proto_in = os.fdopen(proto_in_fd, "rb")
    proto_out = os.fdopen(proto_out_fd, "wb", buffering=0)

    devnull_fd = os.open(os.devnull, os.O_RDWR)
    os.set_inheritable(devnull_fd, False)
    os.dup2(devnull_fd, 0)
    os.dup2(devnull_fd, 1)
    os.dup2(devnull_fd, 2)
    sys.stdin = open(os.devnull, "r", encoding="utf-8", errors="replace")

    ns = {"__name__": "__main__", "__builtins__": __builtins__}
    state = {"workspace_root": None}

    try:
        while True:
            raw = proto_in.readline()
            if not raw:
                break
            line = raw.strip()
            if not line:
                continue
            try:
                req = json.loads(line.decode("utf-8"))
                ok, output = _run_request(req, ns, state, devnull_fd)
            except BaseException as exc:
                ok, output = False, f"Worker protocol error: {exc}"
            payload = json.dumps({"ok": ok, "output": output}, ensure_ascii=False) + "\n"
            proto_out.write(payload.encode("utf-8"))
    finally:
        for handle in (proto_in, proto_out):
            try:
                handle.close()
            except Exception:
                pass
        try:
            os.close(devnull_fd)
        except Exception:
            pass


if __name__ == "__main__":
    main()

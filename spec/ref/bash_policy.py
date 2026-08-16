"""Executable port of lean-proofs/Graff/BashPolicy.lean."""

from __future__ import annotations

METAS = frozenset(";|&><`$\n\r\t\x00")
READ_ONLY_SEED = (
    "ls",
    "cat",
    "head",
    "tail",
    "wc",
    "grep",
    "rg",
    "pwd",
    "which",
    "file",
    "git status",
    "git diff",
    "git log",
    "git show",
)
COMMANDS: tuple[str, ...] = (
    "ls -la",
    "git status",
    "cat src/main.zig",
    "  grep foo bar  ",
    "rm -rf x",
    "cat /etc/passwd",
    "ls; rm x",
    "git push",
    "zig build",
    "zig fmt src",
    "ls ~/projects",
    "cat /abs/file",
    "lsof",
    "echo $(whoami)",
    "echo `id`",
    "foo > bar",
    "a && b",
    "echo $HOME",
    "cat ../outside",
    "prog --file=/abs/path",
    "prog --flag=value",
    "grep foo ./a/b.zig",
    "",
    "ls",
    "git status -s",
    "git statusx",
    "cat a | sh",
    "  ls  ",
    "git log",
    "zig fmt /x.zig",
    "ls /x; rm y",
    "grep foo a/../../b",
)
CUBE = 32


def trim_st(s: str) -> str:
    return s.strip(" \t")


def is_simple(cmd: str) -> bool:
    return not any(ch in METAS for ch in cmd)


def tokens(s: str) -> list[str]:
    return [t for t in s.replace("\t", " ").split(" ") if t]


def token_escapes(tok: str) -> bool:
    if not tok:
        return False
    if tok[0] in "/~":
        return True
    if "=/" in tok or "=~" in tok:
        return True
    return ".." in tok.split("/")


def escapes_cwd(cmd: str) -> bool:
    return any(token_escapes(t) for t in tokens(cmd))


def matches_prefix(cmd: str, prefix: str) -> bool:
    if not cmd.startswith(prefix):
        return False
    return len(cmd) == len(prefix) or cmd[len(prefix)] == " "


def is_read_only_verb(cmd: str) -> bool:
    return any(matches_prefix(cmd, p) for p in READ_ONLY_SEED)


def read_only_allowed(cmd: str) -> bool:
    c = trim_st(cmd)
    if not is_simple(c) or escapes_cwd(c):
        return False
    return is_read_only_verb(c)


def read_only_external(cmd: str) -> bool:
    c = trim_st(cmd)
    return is_simple(c) and escapes_cwd(c) and is_read_only_verb(c)


def check_properties() -> int:
    n = 0
    for cmd in COMMANDS:
        n += 1
        c = trim_st(cmd)
        if read_only_allowed(cmd):
            if not is_simple(c):
                raise ValueError(f"allowed-implies-simple: {cmd!r}")
            if escapes_cwd(c):
                raise ValueError(f"allowed-stays-cwd: {cmd!r}")
            if not is_read_only_verb(c):
                raise ValueError(f"allowed-is-verb: {cmd!r}")
            if read_only_external(cmd):
                raise ValueError(f"allowed-not-external: {cmd!r}")
        if not is_simple(c) and read_only_allowed(cmd):
            raise ValueError(f"not-simple-not-allowed: {cmd!r}")
        if is_simple(c) and escapes_cwd(c) and read_only_allowed(cmd):
            raise ValueError(f"escapes-not-allowed: {cmd!r}")
        ext = read_only_external(cmd)
        want_ext = is_simple(c) and escapes_cwd(c) and is_read_only_verb(c)
        if ext != want_ext:
            raise ValueError(f"external: {cmd!r} got={ext}")
    if n != CUBE:
        raise ValueError(f"bash-cube: n={n} want={CUBE}")
    if is_simple("ls; rm x") or is_simple("echo $HOME"):
        raise ValueError("is-simple: metachar must fail")
    if escapes_cwd("cat src/main.zig") or not escapes_cwd("cat /etc/passwd"):
        raise ValueError("escapes-cwd")
    if matches_prefix("lsof", "ls") or not matches_prefix("ls -la", "ls"):
        raise ValueError("matches-prefix: word boundary")
    if read_only_allowed("zig build") or read_only_allowed("rm -rf x"):
        raise ValueError("seed: zig build / rm are not read-only")
    return n


def payload() -> dict:
    cases = []
    for cmd in COMMANDS:
        cases.append(
            {
                "id": repr(cmd),
                "cmd": cmd,
                "simple": is_simple(cmd),
                "escapes": escapes_cwd(cmd),
                "allowed": read_only_allowed(cmd),
                "external": read_only_external(cmd),
            }
        )
    return {
        "kernel": "bash_policy",
        "version": 1,
        "models": "isSimple+escapesCwd+readOnlyAllowed+readOnlyExternal",
        "out": ["argv-quoting", "cmd.exe", "approvals-session"],
        "seed": list(READ_ONLY_SEED),
        "cases": cases,
    }

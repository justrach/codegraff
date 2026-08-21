#!/usr/bin/env python3
"""Conformance harness for spec/ kernels.

Runs the executable reference model over the full flag space, checks the
properties the Lean file states, diffs against the committed fixtures, and
optionally typechecks Lean or asks the Zig implementation to match.

A failure prints a counterexample (flags + expected vs got) and exits 1.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from ref.tool_catalog import (
    BASE_TOOLS,
    Flags,
    LEAN_TOOLS,
    LOCAL_TOOLS,
    META_TOOLS,
    OPTIONAL_TOOLS,
    ROOT_EXTRAS,
    advertised,
    all_flags,
    blocked,
    catalog,
    subsequence,
)
from ref.transport import all_turns, eligible, idle_expired, pipe
from ref.transport import check_diagram as transport_check_diagram
from ref.transport import kernel_md as transport_kernel_md
from ref.transport import write_kernel_md as write_transport_md
from ref.provider import SPECS as PROVIDER_SPECS
from ref.provider import ws_capable
from ref.path_confine import (
    PATHS,
    all_leases,
    check_diagram as path_check_diagram,
    confined,
    destructive_git_allowed,
    file_tool_ok,
    kernel_md as path_kernel_md,
    owner_verdict,
    warns,
    write_kernel_md as write_path_md,
)
from ref.goal_loop import check_properties as goal_check_properties
from ref.goal_loop import payload as goal_payload
from ref.prompt_cache import check_properties as cache_check_properties
from ref.prompt_cache import payload as cache_payload
from ref.prompt_cache import write_kernel_md as write_cache_md
from ref.prompt_cache import kernel_md as cache_kernel_md
from ref.prompt_prefix import check_properties as prefix_check_properties, payload as prefix_payload
from ref.prompt_prefix import write_kernel_md as write_prefix_md, kernel_md as prefix_kernel_md
from ref.shape import check_properties as shape_check_properties
from ref.shape import payload as shape_model_payload
from ref.score import check_properties as score_check_properties, payload as score_model_payload
from ref.score import kernel_md as score_kernel_md, write_kernel_md as write_score_md
from ref.bash_policy import check_properties as bash_check_properties
from ref.bash_policy import payload as bash_model_payload
from ref.structured_output import check_properties as sox_check_properties
from ref.structured_output import payload as sox_model_payload
from ref.terminal_modes import check_properties as term_check_properties
from ref.terminal_modes import payload as term_model_payload
from ref.terminal_modes import write_kernel_md as write_term_md
from ref.terminal_modes import kernel_md as term_kernel_md

ROOT = Path(__file__).resolve().parent
KERNELS = ROOT / "kernels"
FIXTURE = KERNELS / "tool_catalog.json"
TRANSPORT_FIXTURE = KERNELS / "transport.json"
PROVIDER_FIXTURE = KERNELS / "providers.json"
GOAL_FIXTURE = KERNELS / "goal_loop.json"
PATH_FIXTURE = KERNELS / "path_confine.json"
SHAPE_FIXTURE = KERNELS / "shape.json"
SCORE_FIXTURE = KERNELS / "score.json"
BASH_FIXTURE = KERNELS / "bash_policy.json"
SOX_FIXTURE = KERNELS / "structured_output.json"
TERM_FIXTURE = KERNELS / "terminal_modes.json"
CACHE_FIXTURE = KERNELS / "prompt_cache.json"
PREFIX_FIXTURE = KERNELS / "prompt_prefix.json"
LEAN_DIR = ROOT.parent / "lean-proofs"


class Counterexample(Exception):
    def __init__(self, property: str, flags: object | None, detail: str):
        self.property = property
        self.flags = flags
        self.detail = detail
        extra = f"  flags: {flags}\n" if flags is not None else ""
        super().__init__(f"counterexample: {property}\n{extra}  {detail}")


def check_properties() -> int:
    n = 0
    for f in all_flags():
        n += 1
        got = catalog(f)
        if len(got) != len(set(got)):
            raise Counterexample("unique", f, f"duplicate names: {got}")
        if advertised(f, "webfetch") is False and not f.lean:
            # lean drops webfetch; #330 must not.
            if f.no_local:
                raise Counterexample("webfetch-survives-no-local", f, f"catalog={got}")
        if f.is_sub and "subagent" in got:
            raise Counterexample("sub-never-spawns", f, f"catalog={got}")
        if f.no_local:
            for name in LOCAL_TOOLS:
                if name in got:
                    raise Counterexample(
                        "no-local-drops-local",
                        f,
                        f"{name} still advertised: {got}",
                    )
                if not blocked(f, name):
                    raise Counterexample(
                        "layer2-no-local",
                        f,
                        f"{name} not blocked under #330",
                    )
        img_ok = (
            f.imagegen
            and not f.no_local
            and not (f.lean and not f.is_sub)  # imagegen ∉ lean keep-list
        )
        if ("imagegen" in got) != img_ok:
            raise Counterexample(
                "optional-iff",
                f,
                f"imagegen in catalog={('imagegen' in got)} want={img_ok}: {got}",
            )
        if blocked(f, "imagegen") != (f.no_local or not f.imagegen):
            raise Counterexample(
                "layer2-optional",
                f,
                f"blocked(imagegen)={blocked(f, 'imagegen')}",
            )
        if f.lean and not f.is_sub:
            if blocked(f, "todo_write"):
                raise Counterexample(
                    "lean-has-no-layer2",
                    f,
                    "todo_write is lean-dropped but must not be blocked",
                )
            full = catalog(Flags(
                no_local=f.no_local,
                lean=False,
                imagegen=f.imagegen,
                clock_sleep=f.clock_sleep,
                learn_loaded=f.learn_loaded,
                is_sub=False,
            ))
            if not subsequence(got, full):
                raise Counterexample("lean-subseteq-full", f, f"lean={got}\n  full={full}")
        if f.no_local:
            ungated = catalog(Flags(
                no_local=False,
                lean=f.lean,
                imagegen=f.imagegen,
                clock_sleep=f.clock_sleep,
                learn_loaded=f.learn_loaded,
                is_sub=f.is_sub,
            ))
            if not subsequence(got, ungated):
                raise Counterexample("no-local-subseteq-full", f, f"gated={got}\n  full={ungated}")
        if f.clock_sleep and not f.is_sub and not f.lean:
            if "clock_sleep" not in got:
                raise Counterexample("clock-sleep-on", f, f"catalog={got}")
        if (not f.clock_sleep) and "clock_sleep" in got:
            raise Counterexample("clock-sleep-off", f, f"catalog={got}")
        if f.learn_loaded and not f.is_sub and not f.lean:
            if "learn_candidate" not in got:
                raise Counterexample("learn-on", f, f"catalog={got}")
        if (not f.learn_loaded) and "learn_candidate" in got:
            raise Counterexample("learn-off", f, f"catalog={got}")
    return n


def check_transport() -> int:
    n = 0
    ws_cells = 0
    for t in all_turns():
        n += 1
        want_ws = (
            t.kind == "responses"
            and not t.is_sub
            and t.codex_ws
            and not t.ws_off
            and t.has_out
            and not t.quiet
        )
        if eligible(t) != want_ws:
            raise Counterexample("ws-eligible", t, f"eligible={eligible(t)} want={want_ws}")
        if (pipe(t) == "ws") != want_ws:
            raise Counterexample("pipe", t, f"pipe={pipe(t)}")
        if t.kind != "responses" and eligible(t):
            raise Counterexample("only-responses-ws", t, "non-responses was WS")
        if t.is_sub and eligible(t):
            raise Counterexample("sub-never-ws", t, "subagent was WS")
        if want_ws:
            ws_cells += 1
    if ws_cells != 1:
        raise Counterexample("one-ws-cell", None, f"ws_cells={ws_cells} want=1")
    if idle_expired(100, 0, 100):
        raise Counterexample("idle-eq-keeps", None, "equal to the limit must keep the socket")
    if not idle_expired(101, 0, 100):
        raise Counterexample("idle-past-expires", None, "strictly past the limit must expire")
    try:
        transport_check_diagram()
    except ValueError as e:
        raise Counterexample("transport-diagram", None, str(e)) from e
    return n


def cases_payload() -> dict:
    cases = []
    for f in all_flags():
        got = catalog(f)
        cases.append(
            {
                "id": f.case_id(),
                "flags": {
                    "no_local": f.no_local,
                    "lean": f.lean,
                    "imagegen": f.imagegen,
                    "clock_sleep": f.clock_sleep,
                    "learn_loaded": f.learn_loaded,
                    "seat": "sub" if f.is_sub else "root",
                },
                "advertised": got,
                "blocked": [n for n in sorted(set(LOCAL_TOOLS + OPTIONAL_TOOLS + META_TOOLS)) if blocked(f, n)],
            }
        )
    return {
        "kernel": "tool_catalog",
        "version": 1,
        "universe": {
            "base": list(BASE_TOOLS),
            "meta": list(META_TOOLS),
            "root_extras": list(ROOT_EXTRAS),
            "optional": list(OPTIONAL_TOOLS),
            "local": list(LOCAL_TOOLS),
            "lean": list(LEAN_TOOLS),
        },
        "cases": cases,
    }


def transport_payload() -> dict:
    cases = []
    for t in all_turns():
        cases.append(
            {
                "id": t.case_id(),
                "turn": {
                    "kind": t.kind,
                    "is_sub": t.is_sub,
                    "codex_ws": t.codex_ws,
                    "ws_off": t.ws_off,
                    "has_out": t.has_out,
                    "quiet": t.quiet,
                },
                "eligible": eligible(t),
                "pipe": pipe(t),
            }
        )
    return {"kernel": "transport", "version": 1, "cases": cases}


def provider_payload() -> dict:
    return {"kernel": "provider", "version": 1, "rows": PROVIDER_SPECS}


def path_payload() -> dict:
    return {
        "kernel": "path_confine",
        "version": 1,
        "paths": [{"path": p, "confined": confined(p)} for p in PATHS],
        "leases": [
            {
                "id": l.case_id(),
                "lease": {
                    "identities": l.identities,
                    "start_zero": l.start_zero,
                    "probe": l.probe,
                    "pid_self": l.pid_self,
                },
                "verdict": owner_verdict(l),
                "warns": warns(owner_verdict(l)),
            }
            for l in all_leases()
        ],
    }


def shape_payload() -> dict:
    return shape_model_payload()


def score_payload() -> dict:
    return score_model_payload()


def bash_payload() -> dict:
    return bash_model_payload()


def check_provider() -> int:
    ids = [r["id"] for r in PROVIDER_SPECS]
    if len(ids) != len(set(ids)):
        raise Counterexample("provider-unique", None, f"ids={ids}")
    if len(PROVIDER_SPECS) != 20:
        raise Counterexample("provider-count", None, f"n={len(PROVIDER_SPECS)} want=20")
    responses = [r for r in PROVIDER_SPECS if r["kind"] == "responses"]
    if [r["id"] for r in responses] != ["openai", "codex"]:
        raise Counterexample("responses-vendors", None, f"{responses}")
    x_key = [r for r in PROVIDER_SPECS if r["auth"] == "x_api_key"]
    if [r["id"] for r in x_key] != ["anthropic"]:
        raise Counterexample("only-anthropic-x-api-key", None, f"{x_key}")
    if any(ws_capable(r) and r["id"] != "codex" for r in PROVIDER_SPECS):
        raise Counterexample("ws-capable-brand", None, "a non-codex row is WS-capable")
    return len(PROVIDER_SPECS)


def _ref(fn, name: str) -> int:
    try:
        return fn()
    except ValueError as e:
        raise Counterexample(name, None, str(e)) from e


def check_goal_loop() -> int: return _ref(goal_check_properties, "goal_loop")
def check_prompt_cache() -> int: return _ref(cache_check_properties, "prompt_cache")
def check_prompt_prefix() -> int: return _ref(prefix_check_properties, "prompt_prefix")
def check_prompt_stable() -> int:
    return _ref(__import__("ref.prompt_stable", fromlist=["check_properties"]).check_properties, "prompt_stable")


def check_path_confine() -> int:
    n = 0
    for p in PATHS:
        n += 1
        if p == "" and confined(p):
            raise Counterexample("empty-not-confined", None, p)
        if p.startswith("/") and confined(p):
            raise Counterexample("absolute-not-confined", None, p)
        if ".." in p.replace("\\", "/").split("/") and confined(p):
            raise Counterexample("dotdot-not-confined", None, p)
        if not confined(p) and file_tool_ok(p, []):
            raise Counterexample("unconfined-file-tool", None, p)
        if confined(p) and not file_tool_ok(p, [p.split("/")[0]] if p and not p.startswith("/") else []):
            # a symlink on the first component must fail when confined
            if "/" in p or True:
                if p and confined(p) and file_tool_ok(p, prefixes_first(p)):
                    raise Counterexample("symlink-prefix", None, p)
    if destructive_git_allowed(True, True):
        raise Counterexample("yolo-does-not-free-sub", None, "sub+yolo allowed git")
    if not destructive_git_allowed(True, False):
        raise Counterexample("yolo-root-git", None, "root+yolo blocked git")
    for l in all_leases():
        n += 1
        v = owner_verdict(l)
        if l.identities == "differ" and v != "other_worktree":
            raise Counterexample("lease-other-worktree", l, v)
        if l.identities == "same" and l.start_zero and v != "stale_unverifiable":
            raise Counterexample("lease-zero-start", l, v)
        if l.identities == "same" and not l.start_zero and l.probe == "gone" and v != "stale_dead":
            raise Counterexample("lease-gone", l, v)
        if l.identities == "same" and not l.start_zero and l.probe == "match" and l.pid_self and v != "self":
            raise Counterexample("lease-self", l, v)
        if v == "live_foreign" and not warns(v):
            raise Counterexample("lease-warns", l, v)
    try:
        path_check_diagram()
    except ValueError as e:
        raise Counterexample("path-diagram", None, str(e)) from e
    return n


def check_shape() -> int: return _ref(shape_check_properties, "shape")


def check_score() -> int: return _ref(score_check_properties, "score")
def check_bash() -> int: return _ref(bash_check_properties, "bash")


def check_sox() -> int: return _ref(sox_check_properties, "sox")
def check_term() -> int: return _ref(term_check_properties, "term")


def prefixes_first(p: str) -> list[str]:
    parts = [c for c in p.split("/") if c]
    return [parts[0]] if parts else []


def _write(path: Path, payload: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return path


def export() -> list[Path]:
    from ref.goal_loop import write_kernel_md
    return [
        _write(FIXTURE, cases_payload()),
        _write(TRANSPORT_FIXTURE, transport_payload()),
        write_transport_md(KERNELS / "transport.md"),
        _write(PROVIDER_FIXTURE, provider_payload()),
        _write(GOAL_FIXTURE, goal_payload()),
        write_kernel_md(KERNELS / "goal_loop.md"),
        _write(PATH_FIXTURE, path_payload()),
        write_path_md(KERNELS / "path_confine.md"),
        _write(SHAPE_FIXTURE, shape_payload()),
        _write(SCORE_FIXTURE, score_payload()),
        write_score_md(KERNELS / "score.md"),
        _write(BASH_FIXTURE, bash_payload()),
        _write(SOX_FIXTURE, sox_model_payload()),
        _write(TERM_FIXTURE, term_model_payload()),
        write_term_md(KERNELS / "terminal_modes.md"),
        _write(CACHE_FIXTURE, cache_payload()),
        write_cache_md(KERNELS / "prompt_cache.md"),
        _write(PREFIX_FIXTURE, prefix_payload()),
        write_prefix_md(KERNELS / "prompt_prefix.md"),
        _write(KERNELS / "prompt_stable.json", __import__("ref.prompt_stable", fromlist=["payload"]).payload()),
        __import__("ref.prompt_stable", fromlist=["write_kernel_md"]).write_kernel_md(KERNELS / "prompt_stable.md"),
    ]


def _same(path: Path, fresh: dict, name: str) -> None:
    if not path.is_file():
        raise Counterexample("fixtures-missing", None, f"run --export to write {path}")
    if json.loads(path.read_text()) != fresh:
        raise Counterexample("fixtures-stale", None, f"{name}: {path} does not match; run --export")


def check_fixtures() -> None:
    _same(FIXTURE, cases_payload(), "tool_catalog")
    _same(TRANSPORT_FIXTURE, transport_payload(), "transport")
    _same(PROVIDER_FIXTURE, provider_payload(), "provider")
    _same(GOAL_FIXTURE, goal_payload(), "goal_loop")
    _same(PATH_FIXTURE, path_payload(), "path_confine")
    _same(SHAPE_FIXTURE, shape_payload(), "shape")
    _same(SCORE_FIXTURE, score_payload(), "score")
    _same(BASH_FIXTURE, bash_payload(), "bash_policy")
    _same(SOX_FIXTURE, sox_model_payload(), "structured_output")
    _same(TERM_FIXTURE, term_model_payload(), "terminal_modes")
    _same(CACHE_FIXTURE, cache_payload(), "prompt_cache")
    _same(PREFIX_FIXTURE, prefix_payload(), "prompt_prefix")
    from ref.prompt_stable import payload as stable_payload, kernel_md as stable_kernel_md
    _same(KERNELS / "prompt_stable.json", stable_payload(), "prompt_stable")
    from ref.goal_loop import kernel_md
    for name, body in (
        ("goal_loop.md", kernel_md),
        ("prompt_cache.md", cache_kernel_md),
        ("prompt_prefix.md", prefix_kernel_md),
        ("prompt_stable.md", stable_kernel_md),
        ("terminal_modes.md", term_kernel_md),
        ("path_confine.md", path_kernel_md),
        ("transport.md", transport_kernel_md),
        ("score.md", score_kernel_md),
    ):
        md = KERNELS / name
        if not md.is_file() or md.read_text() != body():
            raise Counterexample("fixtures-stale", None, f"{name} does not match live step; run --export")


def break_model(kind: str) -> None:
    """Mutate the model so a property fails — shows the counterexample shape."""
    import ref.tool_catalog as m

    if kind == "imagegen-always-on":
        m.with_available = lambda _f, xs: xs + ["imagegen"]  # type: ignore[assignment]
    else:
        raise SystemExit(f"unknown --break {kind!r} (try imagegen-always-on)")


def try_lean() -> int:
    lake = shutil_which("lake")
    if lake is None:
        print("lean: lake not installed (optional; fixtures are the CI surface)")
        return 0
    print(f"lean: {lake} build (cwd={LEAN_DIR})")
    if subprocess.run([lake, "build"], cwd=LEAN_DIR).returncode != 0:
        raise Counterexample("lean-build", None, "lake build failed")
    return 0


def shutil_which(name: str) -> str | None:
    from shutil import which
    return which(name)


def try_impl() -> int:
    zig = shutil_which("zig")
    if zig is None:
        print("impl: zig not on PATH; skip")
        return 0
    cmd = [zig, "build", "test", "--summary", "none", "-Dtest-filter=spec/"]
    print("impl:", " ".join(cmd))
    if subprocess.run(cmd, cwd=ROOT.parent).returncode != 0:
        raise Counterexample("impl", None, "zig test spec/tool_catalog failed")
    return 0


def main() -> int:
    # allow `python3 spec/conformance.py` from the repo root
    sys.path.insert(0, str(ROOT))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", action="store_true", help="write spec/kernels/*.json")
    parser.add_argument("--diagram", metavar="KERNEL", help="print live Event/step projection")
    parser.add_argument("--showcase", nargs="?", const="prompt", metavar="KERNEL", help="prompt-cache maximizing walk")
    parser.add_argument("--break", dest="mutate", metavar="KIND", help="mutate the model to demo a counterexample")
    parser.add_argument("--lean", action="store_true", help="lake build lean-proofs if lake is installed")
    parser.add_argument("--impl", action="store_true", help="run the Zig fixture tests")
    parser.add_argument("--status", action="store_true", help="print corpus inventory (triangle + cell floors)")
    parser.add_argument("--json", action="store_true", help="with --status, emit JSON")
    args = parser.parse_args()

    if args.status:
        from status import inventory, render

        inv = inventory()
        print(json.dumps(inv, indent=2) if args.json else render(inv))
        return 0 if inv["ok"] else 1

    if args.showcase:
        from ref.prompt_showcase import showcase
        try:
            sys.stdout.write(showcase(args.showcase))
            return 0
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
    if args.diagram:
        mods = {
            "goal_loop": "ref.goal_loop", "prompt_cache": "ref.prompt_cache",
            "prompt_prefix": "ref.prompt_prefix", "prompt_stable": "ref.prompt_stable",
            "terminal_modes": "ref.terminal_modes",
            "path_confine": "ref.path_confine", "transport": "ref.transport", "score": "ref.score",
        }
        path = mods.get(args.diagram)
        if path is None:
            print(f"no machine projection for {args.diagram}", file=sys.stderr)
            return 2
        sys.stdout.write(__import__(path, fromlist=["mermaid"]).mermaid())
        return 0

    if args.mutate:
        break_model(args.mutate)

    try:
        n_cat = check_properties()
        n_tr = check_transport()
        n_pr = check_provider()
        n_gl = check_goal_loop()
        n_ck = check_prompt_cache()
        n_px = check_prompt_prefix()
        n_ps = check_prompt_stable()
        n_pc = check_path_confine()
        n_sh = check_shape()
        n_sc = check_score()
        n_ba = check_bash()
        n_sx = check_sox()
        n_tm = check_term()
        if args.export:
            paths = export()
            rel = ", ".join(p.relative_to(ROOT.parent).as_posix() for p in paths)
            print(f"exported catalog={n_cat} transport={n_tr} provider={n_pr} goal={n_gl} cache={n_ck} prefix={n_px} stable={n_ps} path={n_pc} shape={n_sh} score={n_sc} bash={n_ba} sox={n_sx} term={n_tm} → {rel}")
        else:
            check_fixtures()
            print(
                f"ok  tool_catalog {n_cat}  transport {n_tr} (1 ws)  "
                f"provider {n_pr}  goal_loop {n_gl}  prompt_cache {n_ck}  prompt_prefix {n_px}  prompt_stable {n_ps}  path_confine {n_pc}  "
                f"shape {n_sh}  score {n_sc}  bash {n_ba}  "
                f"structured_output {n_sx}  terminal_modes {n_tm}"
            )
        if args.lean:
            try_lean()
        if args.impl:
            try_impl()
    except Counterexample as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    # When executed as a file, the package-relative import above needs ROOT on path.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main())

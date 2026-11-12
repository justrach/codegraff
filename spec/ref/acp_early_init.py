"""Executable port of lean-proofs/Graff/AcpEarlyInit.lean.

`graff acp` answers `initialize` at a boot phase boundary. (a) `step` is the
decision `src/acp_early.zig` consults; the system around it (shared stdin,
protocol stdout, dispatch log) is checked over every boot trace up to a bound,
including boundaries whose early answer fails to reach the client. (b) The
response cube: the model's early answer + loop-start replay leave the same
response and latches as the late path in every cell (the Zig conformance test
checks the real engine's bytes on the same cells).

`MUTANTS` are broken designs `check_properties` must reject.
"""

from __future__ import annotations

import json
from itertools import product

STATES = ("booting", "answering", "answered", "passed", "loop")
LINES = ("none", "incomplete", "initialize", "other")
ACTIONS = ("none", "answer", "take", "replay")
EVENTS: tuple[tuple, ...] = (
    tuple(("boundary", acp, line) for acp in (False, True) for line in LINES)
    + (("sent", False), ("sent", True), ("loop_start",))
)

MUTANTS = (
    "answer-early-and-again-in-loop",
    "replay-emits-response",
    "consume-other-first-line",
    "early-can-load-false",
    "skip-replay",
    "take-line-although-answer-failed",
)


def step(s: str, e: tuple, mutant: str | None = None) -> tuple[str, str]:
    if e[0] == "boundary":
        _, acp, line = e
        if s != "booting":
            return s, "none"
        if not acp:
            return "passed", "none"
        if line in ("none", "incomplete"):
            return "booting", "none"
        if line == "initialize":
            return "answering", "answer"
        if mutant == "consume-other-first-line":
            return "answering", "answer"
        return "passed", "none"
    if e[0] == "sent":
        if s != "answering":
            return s, "none"
        if e[1] or mutant == "take-line-although-answer-failed":
            return "answered", "take"
        return "passed", "none"
    if e[0] == "loop_start":
        if s == "answered" and mutant != "skip-replay":
            return "loop", "replay"
        return "loop", "none"
    raise ValueError(f"unknown event {e!r}")


# ── (a) the protocol: Sys over a boot trace ───────────────────────────────


def classify(sys: dict) -> str:
    if not sys["avail"]:
        return "incomplete"
    if not sys["input"]:
        return "none"
    return "initialize" if sys["input"][0][0] == "init" else "other"


def answer_of(m: tuple) -> tuple:
    return ("resp", m[1])


def start(inp: list) -> dict:
    return {"st": "booting", "avail": False, "input": list(inp), "stash": None, "out": [], "disp": []}


def boot_step(acp: bool, s: dict, ev: str, mutant: str | None) -> dict:
    """`ev`: "arrive", "boundary" (an answer it attempts reaches the client) or
    "fail" (a boundary whose answer attempt fails and writes nothing)."""
    s = dict(s, input=list(s["input"]), out=list(s["out"]), disp=list(s["disp"]))
    if ev == "arrive":
        s["avail"] = True
        return s
    st, act = step(s["st"], ("boundary", acp, classify(s)), mutant)
    s["st"] = st
    if act != "answer":
        return s
    ok = ev == "boundary"
    st, act = step(st, ("sent", ok), mutant)
    s["st"] = st
    if act == "take" and s["input"]:
        m = s["input"].pop(0)
        s["stash"] = m
        if ok:
            s["out"].append(answer_of(m))
    return s


def loop_start(s: dict, mutant: str | None) -> dict:
    s = dict(s, input=list(s["input"]), out=list(s["out"]), disp=list(s["disp"]))
    st, act = step(s["st"], ("loop_start",), mutant)
    s["st"] = st
    if act == "replay" and s["stash"] is not None:
        m = s["stash"]
        s["stash"] = None
        if mutant == "answer-early-and-again-in-loop":
            s["input"].insert(0, m)  # handed back to the queue: the loop answers it again
        else:
            s["disp"].append(m)
            if mutant == "replay-emits-response":
                s["out"].append(answer_of(m))
    return s


def drain(s: dict) -> dict:
    s = dict(s, out=list(s["out"]), disp=list(s["disp"]))
    for m in s["input"]:
        s["disp"].append(m)
        s["out"].append(answer_of(m))
    s["input"] = []
    return s


def run_early(acp: bool, inp: list, trace: tuple, mutant: str | None = None) -> tuple[dict, dict, dict]:
    s = start(inp)
    for ev in trace:
        s = boot_step(acp, s, ev, mutant)
    booted = s
    started = loop_start(s, mutant)
    return booted, started, drain(started)


def run_late(inp: list) -> dict:
    return drain(loop_start(start(inp), None))


def inputs(max_len: int = 3) -> list[list]:
    out = []
    for n in range(max_len + 1):
        for kinds in product(("init", "other"), repeat=n):
            out.append([(k, i) for i, k in enumerate(kinds)])
    return out


def traces(max_len: int = 5) -> list[tuple]:
    out = []
    for n in range(max_len + 1):
        out.extend(product(("arrive", "boundary", "fail"), repeat=n))
    return out


def check_protocol(mutant: str | None = None) -> int:
    n = 0
    for acp, inp, tr in product((False, True), inputs(), traces()):
        n += 1
        booted, started, early = run_early(acp, inp, tr, mutant)
        late = run_late(inp)
        where = f"acp={acp} input={inp} trace={tr}"
        if early["out"] != late["out"]:
            raise ValueError(f"early_out_eq_late: {where}: {early['out']} != {late['out']}")
        if early["disp"] != late["disp"]:
            raise ValueError(f"early_disp_eq_late: {where}: {early['disp']} != {late['disp']}")
        if started["out"] != booted["out"]:
            raise ValueError(f"replay_silent: {where}")
        if len(booted["out"]) > 1 or booted["disp"]:
            raise ValueError(f"boot_writes_at_most_one: {where}")
        if inp and inp[0][0] == "init" and early["out"].count(("resp", 0)) != 1:
            raise ValueError(f"initialize_answered_once: {where}")
        if inp and inp[0][0] == "other" and (booted["input"] != inp or booted["out"]):
            raise ValueError(f"other_first_untouched: {where}")
        s = start(inp)
        for ev in tr:
            failed = boot_step(acp, s, "fail", mutant)
            if (failed["input"], failed["stash"], failed["out"]) != (s["input"], s["stash"], s["out"]):
                raise ValueError(f"failed_answer_not_consumed: {where} at {ev}")
            s = boot_step(acp, s, ev, mutant)
    return n


def check_step_table(mutant: str | None = None) -> int:
    n = 0
    for s, e in product(STATES, EVENTS):
        n += 1
        nxt, act = step(s, e, mutant)
        if (act == "answer") != (s == "booting" and e == ("boundary", True, "initialize")):
            raise ValueError(f"step_answer_iff: {s} {e}")
        if (act == "take") != (s == "answering" and e == ("sent", True)):
            raise ValueError(f"step_take_iff: {s} {e}")
        if s == "answering" and e == ("sent", False) and (nxt, act) != ("passed", "none"):
            raise ValueError(f"step_failed_passes: {s} {e}")
        if (act == "replay") != (s == "answered" and e == ("loop_start",)):
            raise ValueError(f"step_replay_iff: {s} {e}")
        if e == ("loop_start",) and nxt != "loop":
            raise ValueError(f"loop_start_reaches_loop: {s}")
        if s == "loop" and (nxt, act) != ("loop", "none"):
            raise ValueError(f"loop_absorbing: {e}")
    return n


def step_rows() -> list[dict]:
    rows = []
    for s, e in product(STATES, EVENTS):
        nxt, act = step(s, e)
        if e[0] == "loop_start":
            ev = {"kind": "loop_start"}
        elif e[0] == "sent":
            ev = {"kind": "sent", "ok": e[1]}
        else:
            ev = {"kind": "boundary", "acp": e[1], "line": e[2]}
        rows.append({"state": s, "event": ev, "next": nxt, "action": act})
    return rows


# ── (b) the response cube ──────────────────────────────────────────────────

PVS = ("missing", 0, 1, 2, 9)
SUBS = ("absent", "object", "null")
BGS = ("absent", "true", "false")
SEEDS = (0, 1, 0x5EED)
BOOT_LATCH = {"v2": False, "seed": 0, "t3": False, "elicit": False, "compaction": False, "subagents": False, "bg": False}


def is_v2(c: dict) -> bool:
    return c["gate"] and c["pv"] != "missing" and c["pv"] >= 2


def resp(c: dict, can_load: bool) -> dict:
    v2 = is_v2(c)
    return {"protocol_version": 2 if v2 else 1, "v2_shape": v2, "can_load": can_load, "auth_terminal": (not v2) or c["extras"]}


def latch(prev: dict, c: dict, seed: int) -> dict:
    v2 = is_v2(c)
    return {
        "v2": v2,
        "seed": seed if v2 else prev["seed"],
        "t3": c["extras"],
        "elicit": c["extras"],
        "compaction": c["extras"] or v2,
        "subagents": (not v2) and c["sub"] == "object",
        "bg": c["bg"] == "true",
    }


def late(c: dict, seed: int) -> tuple[dict, dict]:
    return latch(BOOT_LATCH, c, seed), resp(c, c["can_load"])


def early(c: dict, seed: int, mutant: str | None = None) -> tuple[dict, dict]:
    scratch = latch(BOOT_LATCH, c, 0)
    can_load = False if mutant == "early-can-load-false" else c["can_load"]
    out = resp(c, can_load)
    if mutant == "skip-replay":
        # The scratch dispatch's fields are dropped; the live one stays fresh.
        return dict(scratch, subagents=False, bg=False), out
    return latch(scratch, c, seed), out


def request(c: dict, idx: int) -> str:
    caps: dict = {"fs": {}}
    if c["sub"] == "object":
        caps["subagents"] = {}
    elif c["sub"] == "null":
        caps["subagents"] = None
    if c["bg"] != "absent":
        caps["_meta"] = {"graff/backgroundSubagents": c["bg"] == "true"}
    params: dict = {}
    if c["pv"] != "missing":
        params["protocolVersion"] = c["pv"]
    if c["extras"]:
        params["clientInfo"] = {"name": "t3-code", "version": "1"}
        caps["elicitation"] = {"form": {}}
        caps["session"] = {"compaction": True}
        params["capabilities"] = {"auth": {"terminal": {}}}
    params["clientCapabilities"] = caps
    return json.dumps({"jsonrpc": "2.0", "id": idx, "method": "initialize", "params": params}, separators=(",", ":"))


def cells() -> list[dict]:
    rows = []
    for pv, gate, sub, bg, can_load, extras in product(PVS, (False, True), SUBS, BGS, (False, True), (False, True)):
        c = {"pv": pv, "gate": gate, "sub": sub, "bg": bg, "can_load": can_load, "extras": extras}
        lat, out = late(c, SEEDS[-1])
        rows.append(dict(
            c,
            id=f"pv{pv}.g{int(gate)}.sub{sub}.bg{bg}.cl{int(can_load)}.x{int(extras)}",
            request=request(c, len(rows)),
            response=out,
            latches={k: v for k, v in lat.items() if k != "seed"},
        ))
    return rows


def check_cube(mutant: str | None = None) -> int:
    n = 0
    for c in cells():
        n += 1
        for seed in SEEDS:
            if early(c, seed, mutant) != late(c, seed):
                raise ValueError(f"cube_early_eq_late: {c['id']} seed={seed}")
        lat = late(c, 7)[0]
        if lat["v2"] and lat["subagents"]:
            raise ValueError(f"cube_v2_no_subagents: {c['id']}")
    v2_cells = sum(1 for c in cells() if is_v2(c))
    if v2_cells != 72:
        raise ValueError(f"cube_v2_cells: {v2_cells}")
    return n


def _check(mutant: str | None) -> int:
    return check_step_table(mutant) + check_protocol(mutant) + check_cube(mutant)


def check_properties() -> int:
    """Cells checked (step table + cube); every mutant must be rejected."""
    _check(None)
    for m in MUTANTS:
        try:
            _check(m)
        except ValueError:
            continue
        raise ValueError(f"mutant survived: {m}")
    return len(STATES) * len(EVENTS) + len(cells())


def payload() -> dict:
    return {
        "kernel": "acp_early_init",
        "version": 1,
        "universe": {"states": list(STATES), "lines": list(LINES), "actions": list(ACTIONS)},
        "mutants_rejected": list(MUTANTS),
        "step": step_rows(),
        "cases": cells(),
    }

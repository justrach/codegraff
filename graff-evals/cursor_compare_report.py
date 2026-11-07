#!/usr/bin/env python3
"""Offline, private Graff/native-Cursor comparison reports; no provider calls."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics
from typing import Optional

ARMS = ("graff", "cursor")
FAILURE_FIELDS = (
    "harness", "task", "rep", "artifact_ok", "outcome_ok", "exit", "timed_out",
    "routing_ok", "native_completion_ok", "verifiers_unchanged", "check_note", "error",
)


def clean(row: dict) -> bool:
    """Match the receipt's complete clean-pass gate, not artifact success alone."""
    return bool(
        row.get("outcome_ok") and row.get("routing_ok")
        and row.get("native_completion_ok") and row.get("exit") == 0
        and not row.get("timed_out") and row.get("verifiers_unchanged")
    )


def numeric(value) -> bool:
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def metric(values, median: bool = False) -> Optional[float]:
    values = list(values)
    if not values:
        return None
    return round((statistics.median if median else statistics.mean)(values), 3)


def aggregate(items: list, arm: str) -> dict:
    wall = [r["wall_s"] for r in items if numeric(r.get("wall_s"))]
    passed = [r["wall_s"] for r in items if clean(r) and numeric(r.get("wall_s"))]
    # These are Cursor's own measurements, never a matched Graff metric.
    native = [r["native_task_duration_s"] for r in items
              if arm == "cursor" and numeric(r.get("native_task_duration_s"))]
    overhead = [r["outside_native_duration_s"] for r in items
                if arm == "cursor" and numeric(r.get("outside_native_duration_s"))]
    return {
        "runs": len(items), "clean_pass": sum(clean(r) for r in items),
        "artifact_pass": sum(bool(r.get("artifact_ok")) for r in items),
        "timeouts": sum(bool(r.get("timed_out")) for r in items),
        "routing_verified": sum(bool(r.get("routing_ok")) for r in items),
        "mean_wall_s": metric(wall), "median_wall_s": metric(wall, median=True),
        "wall_reported_runs": len(wall),
        "passing_mean_wall_s": metric(passed),
        "passing_median_wall_s": metric(passed, median=True),
        "passing_wall_reported_runs": len(passed),
        "native_task_duration_mean_s": metric(native),
        "native_task_duration_median_s": metric(native, median=True),
        "outside_native_duration_mean_s": metric(overhead),
        "outside_native_duration_median_s": metric(overhead, median=True),
        "native_duration_reported_runs": len(native),
        "outside_native_duration_reported_runs": len(overhead),
    }


def paired_stats(items: list) -> dict:
    pairs = {}
    for row in items:
        pairs.setdefault((row["task"], row["rep"]), {})[row["harness"]] = row
    both_passed = [p for p in pairs.values() if all(clean(p[a]) for a in ARMS)]
    timed = [p for p in both_passed if all(numeric(p[a].get("wall_s")) for a in ARMS)]
    means = {a: metric(p[a]["wall_s"] for p in timed) for a in ARMS}
    medians = {a: metric((p[a]["wall_s"] for p in timed), median=True) for a in ARMS}
    reduction = None
    if timed:
        graff_mean = statistics.mean(p["graff"]["wall_s"] for p in timed)
        cursor_mean = statistics.mean(p["cursor"]["wall_s"] for p in timed)
        if cursor_mean > 0:
            reduction = round((1 - graff_mean / cursor_mean) * 100, 1)
    return {
        "pairs": len(pairs), "both_clean_passed": len(both_passed),
        "timed_both_clean_passed": len(timed),
        "graff_faster_on_both_passing_pairs": sum(
            p["graff"]["wall_s"] < p["cursor"]["wall_s"] for p in timed),
        "mean_wall_s": means, "median_wall_s": medians,
        "graff_wall_reduction_percent": reduction,
    }


def validate(meta: dict, rows: list) -> None:
    if not isinstance(meta, dict):
        raise ValueError("metadata.json must contain an object")
    for name, allowed in (
        ("preset", ("argon", "xai-sub")), ("provider", ("codegraff", "xai")),
        ("effort", ("low", "high")), ("mode", ("smoke", "subset", "full")),
    ):
        if meta.get(name) not in allowed:
            raise ValueError("metadata %s must be one of %s" % (name, ", ".join(allowed)))
    for name in ("repetitions", "workers"):
        if type(meta.get(name)) is not int or meta[name] < 1:
            raise ValueError("metadata %s must be a positive integer" % name)
    models = meta.get("models")
    if not isinstance(models, dict) or any(
        not isinstance(models.get(a), str) or not models[a] for a in ARMS
    ):
        raise ValueError("metadata models must name both graff and cursor model ids")
    tasks = meta.get("tasks")
    if (not isinstance(tasks, list) or not tasks
            or any(not isinstance(t, str) or not t for t in tasks)
            or len(tasks) != len(set(tasks))):
        raise ValueError("metadata tasks must be a nonempty list of unique task names")
    expected = {(a, t, rep) for a in ARMS for t in tasks
                for rep in range(1, meta["repetitions"] + 1)}
    observed = Counter()
    task_suites = {}
    for index, row in enumerate(rows, 1):
        if not isinstance(row, dict):
            raise ValueError("result row %d must be an object" % index)
        arm, task, rep = (row.get(k) for k in ("harness", "task", "rep"))
        if not isinstance(arm, str) or not isinstance(task, str) or type(rep) is not int:
            raise ValueError("result row %d needs harness/task strings and an integer rep" % index)
        observed[(arm, task, rep)] += 1
        suite = row.get("suite")
        if not isinstance(suite, str) or not suite or suite == "all":
            raise ValueError("result row %d needs a named suite (not 'all')" % index)
        previous = task_suites.setdefault(task, suite)
        if suite != previous:
            raise ValueError("task %r has inconsistent suites: %r and %r" % (task, previous, suite))
        for field in ("wall_s", "native_task_duration_s", "outside_native_duration_s"):
            value = row.get(field)
            if value is not None and (not numeric(value) or value < 0):
                raise ValueError("result row %d has invalid %s" % (index, field))
        if "mode" in row and row["mode"] != meta["mode"]:
            raise ValueError("result row %d mode differs from metadata; do not mix smoke/full" % index)
    missing = sorted(expected - set(observed))
    extras = sorted(set(observed) - expected)
    duplicates = sorted(k for k, count in observed.items() if count > 1)
    if missing or extras or duplicates:
        parts = []
        for label, keys in (("missing", missing), ("unexpected", extras), ("duplicate", duplicates)):
            if keys:
                preview = ", ".join("%s/%s/rep=%s" % k for k in keys[:8])
                parts.append("%s (%d): %s%s" % (
                    label, len(keys), preview, " ..." if len(keys) > 8 else ""))
        raise ValueError("invalid task/repetition/arm matrix: " + "; ".join(parts))


def caveats(meta: dict) -> list:
    return [
        "Same named model, different provider backends: this is not a provider-controlled "
        "causal ablation of the harness alone. See the recorded model ids and comparison kind.",
        "Both arms request %s effort on their own scales; requested effort scales and "
        "provider-side reasoning implementations differ." % meta["effort"],
        "%d small deterministic fixtures, %d repetitions per arm, %d workers; mode: %s. "
        "This is a small fixture sample, not evidence about large real-world repositories."
        % (len(meta["tasks"]), meta["repetitions"], meta["workers"], meta["mode"]),
        "Graff binary SHA-256 and Cursor version are recorded in metadata, not inferred "
        "from current installations. No claim of a clean source tree is made.",
        "Cursor uses native CLI agent -p, not desktop Harness or its SDK transport.",
        "Synthetic sandboxes use isolated login snapshots, fixture-only MCP, and no "
        "personal project context; credentials are not refreshed.",
        "Smoke runs are excluded from full results. A smoke-mode report is only a smoke "
        "report, not a full benchmark. Only the supplied root's result file is read.",
        "All runs, including failures, are retained. All-run wall timings are separate "
        "from passing-only matched task/repetition pairs; both-pass denominators are explicit.",
        "first_out measures any output including startup events, not time to first model "
        "token (TTFT). Wall time is task process lifetime.",
        "Cursor native task duration and outside-native overhead are reported separately "
        "with their own measurement counts. They are self-reported, not a comparable Graff "
        "metric; outside-native wall time includes CLI startup/teardown.",
        "Comparable dollar cost and model/API-call counts are unknown, never zero. "
        "Native usage receipts, if present, do not establish comparable prices or call counts.",
        "These are private local reports. The reporter never publishes them or makes "
        "network or model calls.",
    ]


def cell(value) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def seconds(value) -> str:
    return "unknown" if value is None else "%.2fs" % value


def markdown(report: dict) -> str:
    meta, summary = report["metadata"], report["summary"]
    lines = [
        "# %s in Graff and native Cursor" % cell(meta["preset"]), "",
        "Private local report — not published.", "",
        "Created: %s. Mode: **%s**. Comparison: %s."
        % (cell(meta.get("created_at", "unknown")), meta["mode"],
           cell(meta.get("comparison_kind", "unknown"))), "",
        "Graff: `%s` via `%s`. Cursor: `%s` via native `agent -p`. Requested effort: %s "
        "on each arm's own scale. %d tasks × %d repetitions × two arms; %d workers."
        % (cell(meta["models"]["graff"]), cell(meta["provider"]),
           cell(meta["models"]["cursor"]), meta["effort"], len(meta["tasks"]),
           meta["repetitions"], meta["workers"]), "",
        "Graff SHA-256: `%s`. Cursor version: `%s`."
        % (cell(meta.get("graff_sha256", "unknown")), cell(meta.get("cursor_version", "unknown"))),
        "",
        "| Suite | System | Clean pass | Mean wall (all runs) | Median wall (all runs) | Measured runs |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for suite, arms in summary.items():
        for arm, stats in arms.items():
            lines.append("| %s | %s | %d/%d | %s | %s | %d/%d |" % (
                cell(suite), arm, stats["clean_pass"], stats["runs"],
                seconds(stats["mean_wall_s"]), seconds(stats["median_wall_s"]),
                stats["wall_reported_runs"], stats["runs"]))
    lines += ["", "## Matched passing-only pairs", "",
              "Means and medians below use the same both-clean, timed pairs for both arms.", "",
              "| Suite | Both clean / all pairs | Timed both-clean pairs | Graff mean / median | Cursor mean / median | Graff faster |",
              "|---|---:|---:|---:|---:|---:|"]
    for suite, paired in report["paired_by_suite"].items():
        timed = paired["timed_both_clean_passed"]
        lines.append("| %s | %d/%d | %d/%d | %s / %s | %s / %s | %d/%d |" % (
            cell(suite), paired["both_clean_passed"], paired["pairs"], timed,
            paired["both_clean_passed"], seconds(paired["mean_wall_s"]["graff"]),
            seconds(paired["median_wall_s"]["graff"]),
            seconds(paired["mean_wall_s"]["cursor"]),
            seconds(paired["median_wall_s"]["cursor"]),
            paired["graff_faster_on_both_passing_pairs"], timed))
    lines += ["", "## Cursor native timing (not a matched Graff metric)", "",
              "| Suite | Native mean / median | Native measured | Outside-native mean / median | Outside measured |",
              "|---|---:|---:|---:|---:|"]
    for suite, arms in summary.items():
        stats = arms["cursor"]
        lines.append("| %s | %s / %s | %d/%d | %s / %s | %d/%d |" % (
            cell(suite), seconds(stats["native_task_duration_mean_s"]),
            seconds(stats["native_task_duration_median_s"]),
            stats["native_duration_reported_runs"], stats["runs"],
            seconds(stats["outside_native_duration_mean_s"]),
            seconds(stats["outside_native_duration_median_s"]),
            stats["outside_native_duration_reported_runs"], stats["runs"]))
    lines += ["", "## Measurement notes", ""]
    for key in ("credentials", "latency_note", "runtime_cache"):
        lines.append("- %s: %s" % (key, cell(meta.get(key, "unknown"))))
    lines += ["", "## Qualification", ""]
    lines += ["- " + c for c in report["caveats"]]
    lines += ["", "## Non-clean runs", ""]
    if not report["failures"]:
        lines.append("None.")
    else:
        lines += ["| System | Task | Rep | Artifact | Outcome | Routing | Native completion | Exit | Timeout | Verifiers unchanged |",
                  "|---|---|---:|---|---|---|---|---:|---|---|"]
        keys = ("harness", "task", "rep", "artifact_ok", "outcome_ok", "routing_ok",
                "native_completion_ok", "exit", "timed_out", "verifiers_unchanged")
        for row in report["failures"]:
            lines.append("| " + " | ".join(cell(row.get(k)) for k in keys) + " |")
        lines += ["", "Failure notes are retained in results.json; complete run receipts remain in the private comparison root."]
    return "\n".join(lines) + "\n"


def without_root(value, roots: list):
    """Keep report contents relocatable, including root paths embedded in errors."""
    if isinstance(value, str):
        for root in roots:
            value = value.replace(root, "<root>")
        return value
    if isinstance(value, list):
        return [without_root(item, roots) for item in value]
    if isinstance(value, dict):
        return {without_root(k, roots): without_root(v, roots) for k, v in value.items()}
    return value


def summarize(root: Path, output: Path) -> dict:
    """Validate one complete 1-based run matrix and write its private local report."""
    root, output = Path(root), Path(output)
    meta = json.loads((root / "metadata.json").read_text(encoding="utf-8"))
    rows = []
    for line_number, line in enumerate(
        (root / "comparison" / "results.jsonl").read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise ValueError("invalid comparison/results.jsonl JSON at line %d" % line_number) from exc
    validate(meta, rows)
    suites = ["all", "core", "mcp"] + sorted({r["suite"] for r in rows} - {"core", "mcp"})
    groups = {s: [r for r in rows if s == "all" or r["suite"] == s] for s in suites}
    summary = {s: {a: aggregate([r for r in group if r["harness"] == a], a)
                   for a in ARMS} for s, group in groups.items()}
    paired = {s: paired_stats(group) for s, group in groups.items()}
    report = {
        "metadata": meta, "summary": summary, "paired": paired["all"],
        "paired_by_suite": paired,
        "per_task": {t: {a: aggregate([r for r in rows if r["task"] == t
                                     and r["harness"] == a], a) for a in ARMS}
                     for t in meta["tasks"]},
        "failures": [{k: r.get(k) for k in FAILURE_FIELDS} for r in rows if not clean(r)],
        "caveats": caveats(meta),
    }
    roots = sorted({str(root.absolute()), str(root.resolve())}, key=len, reverse=True)
    # A filesystem root cannot be safely scrubbed by replacing every slash.
    if any(Path(p).parent == Path(p) for p in roots):
        raise ValueError("comparison root must not be the filesystem root")
    report = without_root(report, roots)
    output.mkdir(parents=True, exist_ok=True)
    (output / "results.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    (output / "RESULTS.md").write_text(markdown(report), encoding="utf-8")
    print(json.dumps({
        "pass": {a: {"clean": summary["all"][a]["clean_pass"],
                     "runs": summary["all"][a]["runs"]} for a in ARMS},
        "wall": {a: {k: summary["all"][a][k] for k in ("mean_wall_s", "median_wall_s")}
                 for a in ARMS},
        "pairs": paired["all"], "failures": len(report["failures"]),
    }, separators=(",", ":")))
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        summarize(args.root, args.output)
    except (OSError, ValueError) as exc:
        parser.exit(1, "report failed: %s\n" % exc)


if __name__ == "__main__":
    main()

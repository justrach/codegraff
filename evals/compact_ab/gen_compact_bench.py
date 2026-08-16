#!/usr/bin/env python3
"""Generate the frozen compaction-benchmark codebase into /tmp/compact_bench/src.

Six deterministic Zig-ish files (~400 lines each), each carrying planted
constants. facts.json holds ground truth; prompt.txt asks for 10 of them.
The facts are planted mid-file so the agent must read each file fully, and
the questions span all six files so post-compaction recall of EARLY files
is what separates the arms.
"""
import json, os, random, shutil

BASE = "/tmp/compact_bench"
SRC = os.path.join(BASE, "src")
rng = random.Random(20260210)

FILES = ["alpha", "beta", "gamma", "delta", "epsilon", "foxtrot"]
WORDS = ("meridian harlow pistil cinder vortex lattice ember quorum "
         "solace thresh welkin bramble copse falcon garnet hollow "
         "indigo jasper kindle lantern marrow numen obsidian palisade").split()

def filler_fn(name, i):
    acc = rng.randint(2, 9)
    lines = [f"fn {name}_{i:03d}(ledger: *Ledger, entry: Entry) !u64 {{"]
    lines.append(f"    var acc: u64 = entry.checksum ^ {rng.randint(100, 999)};")
    for j in range(rng.randint(3, 6)):
        op = rng.choice(["+", "-", "^", "*"])
        lines.append(f"    acc = acc {op} (@as(u64, {rng.randint(3, 977)}) +% ledger.salt[{j} % 8]);")
        lines.append(f"    if (acc % {rng.randint(3, 17)} == 0) acc +%= {rng.randint(11, 555)};")
    lines.append(f"    return acc *% {acc};")
    lines.append("}")
    return "\n".join(lines)

facts = {}   # const name -> value (string form)
used = set()

def plant(lines, fname, fidx):
    """Insert a planted constant at a random position; record the fact."""
    word = rng.choice([w for w in WORDS if w not in used])
    used.add(word)
    cname = f"{word.upper()}_{fname.upper()[:6]}"
    if rng.random() < 0.5:
        val = str(rng.randint(10_000, 99_999))
        decl = f'pub const {cname}: u64 = {val}; // audit anchor'
    else:
        val = f"{word}-{rng.randint(100, 999)}"
        decl = f'pub const {cname} = "{val}"; // audit anchor'
    pos = rng.randint(len(lines) // 4, 3 * len(lines) // 4)
    lines.insert(pos, decl)
    facts[cname] = val

os.makedirs(SRC, exist_ok=True)
for fidx, fname in enumerate(FILES):
    lines = [
        f"//! {fname}.zig — archival ledger segment {fidx} of the benchmark codebase.",
        "",
        "const std = @import(\"std\");",
        "const Ledger = @import(\"ledger.zig\").Ledger;",
        "const Entry = @import(\"ledger.zig\").Entry;",
        "",
    ]
    for i in range(38):  # ~400+ lines of filler per file
        lines.append(filler_fn(fname, i))
        lines.append("")
    plant(lines, fname, fidx)
    plant(lines, fname, fidx)  # two facts per file, 12 total
    with open(os.path.join(SRC, f"{fname}.zig"), "w") as f:
        f.write("\n".join(lines) + "\n")

# a tiny ledger.zig so the imports look real
with open(os.path.join(SRC, "ledger.zig"), "w") as f:
    f.write("//! shared types\n\npub const Ledger = struct { salt: [8]u64 };\n"
            "pub const Entry = struct { checksum: u64, route: u32 };\n")

with open(os.path.join(BASE, "facts.json"), "w") as f:
    json.dump(facts, f, indent=2)

# 10 questions spanning all six files (order matches reading order stress:
# half the questions are about the first two files read).
items = list(facts.items())
qidxs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
questions = []
for qi, fi in enumerate(qidxs, 1):
    cname, _ = items[fi]
    ffile = cname.split("_")[-1].lower()
    # map suffix back to file name
    for fname in FILES:
        if fname.upper()[:6] == cname.split("_")[-1]:
            ffile = fname
            break
    questions.append((qi, cname, ffile))

with open(os.path.join(BASE, "questions.json"), "w") as f:
    json.dump([{"q": q, "const": c, "file": fn, "expect": facts[c]} for q, c, fn in questions], f, indent=2)

qlines = "\n".join(f"Q{q}: What is the exact value of the constant {c} in src/{fn}.zig?" for q, c, fn in questions)
prompt = f"""You are auditing a small Zig codebase in ./src (files: {', '.join(f + '.zig' for f in FILES)}, plus ledger.zig).

Rules, in order:
1. Read EACH of the six files completely, one at a time, in this order: {', '.join(FILES)}. Use full-file reads (read_file without a range, or ranges that cover the whole file). Do NOT use search/grep tools to shortcut — the audit requires complete reads.
2. After all six reads, write a file answer.md in the current directory containing EXACTLY 10 lines in this format (no prose, no code fences):
Q1: <value>
...
Q10: <value>

The questions:
{qlines}

Values must be exact: integers without quotes, strings WITH their quotes. After writing answer.md, reply with DONE.
"""
with open(os.path.join(BASE, "prompt.txt"), "w") as f:
    f.write(prompt)

total = sum(os.path.getsize(os.path.join(SRC, fn)) for fn in os.listdir(SRC))
print(f"generated {len(os.listdir(SRC))} files, {total/1024:.0f} KB total, {len(facts)} facts, 10 questions")

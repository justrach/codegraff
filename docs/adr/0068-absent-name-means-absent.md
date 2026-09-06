# 0068. An absent name means absent: breadth-first layout, sibling hints, redirects are not vetoes

Status: accepted 2026-09-07

## Context

The root prompt tells the model that the Project layout segment "is the
tree" and to read from it instead of spending turns on `ls`/`find`. The
segment was filled depth-first under a 300-entry / 6 KB cap, so in a
workspace with about sixty top-level entries the first eight directories
spent the whole budget and the rest of the top level never appeared. A
user then named one of the missing folders with a one-letter slip. The
model trusted the tree, concluded the name must be a remote host, tried
ssh, got a bare "was not found" from `codedb list_dir`, recorded the
misreading as a standing constraint through `note_constraint`, and asked
the user where the folder was. A plain listing of the working directory,
six tool calls later, answered it.

Three harness behaviors compounded: a tree that omits top-level names
while claiming to be the tree, a not-found reply with nothing to try
next from the tool the prompt prefers over `ls`, and a constraint trigger
worded so that any "no, ..." reads as a veto.

## Decision

- `repo_map` selects breadth-first and round-robin: every top-level entry
  before any child, then each directory's first child before any second,
  under the same caps. Emission stays a depth-first path list, and the
  trailer names the top-level directories that were not fully expanded.
  A top-level name missing from the segment is therefore missing from
  the tree, and the caller need not `ls` to check.
- `codedb list_dir` on a missing path names the closest sibling entries
  (edit distance over a case- and separator-insensitive form; containment
  counts as close) and lists the parent, so the next call can be the
  right one.
- The `note_constraint` trigger records a way of working the user forbids.
  A redirect of this turn's target ("no, I meant X", "look at Y instead")
  is followed, not recorded. The tool description says the same.

## Consequences

Deep entries are shared across directories instead of exhausting the
budget on the first one, so a fat directory shows fewer of its files;
`list_dir` on demand still lists any of them. The not-found reply grows
by up to about 1.3 KB of sibling names. Fewer standing constraints are
recorded from course corrections; a user who wants a redirect kept as a
rule can say so or use `/never`. Revisit if a model measurably reads
the layout worse in tree-order-with-gaps than in the old prefix-complete
shape, or if sibling hints are shown to mislead more often than they help.

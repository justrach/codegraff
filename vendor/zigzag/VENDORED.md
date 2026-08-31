# Vendored Zigzag

This directory contains Zigzag 0.1.2 from upstream commit
`ad3c8b5d70deba10fef1a0cc33334b8666fb8400`.

The renderer carries one local compatibility patch: rows are erased before
they are painted so an exact-width final cell survives on xterm-compatible
terminals.

CodeGraff vendors the dependency because Zigzag's upstream build script still
references the removed Zig 0.16 `b.args` field. The local build script exports
only the `zigzag` module required by CodeGraff, keeping the dependency usable
with the pinned Zig 0.17 development toolchain without carrying example and
test build steps into the harness build graph.

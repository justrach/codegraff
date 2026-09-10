# 0097. Offline PTY probes own their clipboard command boundary

Status: accepted 2026-09-10

## Context

The selection, click, and scrollbar probes can write the same host clipboard.
Concurrent writes make otherwise correct selection assertions fail (#836).
Serializing one pool does not protect it from another pool or from applications,
and restoring the clipboard afterwards can overwrite newly copied user content.

## Decision

The offline tuiguard pool gives each probe a temporary command-backed clipboard.
Private `pbcopy`, `pbpaste`, and `xclip` commands are prepended to that probe's
PATH and inherited by its Graff child. They preserve the subprocess copy/paste
boundary and exact bytes without reading or writing the user's clipboard.

Keep these environments per probe, never mutate the parent's environment, and
remove their files after the probe exits or its process group is terminated.
Independent probes remain parallel; no selection or OSC52 assertion is skipped.

## Consequences

Gate runs test selection, subprocess delivery, and OSC52 bytes deterministically
without interfering with concurrent runs or normal desktop use. They do not test
the operating system's clipboard service. Direct invocation of the individual
probe scripts retains that integration path when it is explicitly wanted.

A private `xclip` that treats every non-pbpaste invocation as a write blocks on
stdin. Hover (and any probe that only finds `xclip` on PATH) never finishes a
paint sweep. Read when stdin stays quiet; keep `-i`/`pbcopy` as writes.

The pool integrity suite covers copy/paste, independent environments, cleanup,
quiet-stdin reads, and environment inheritance. The real-binary pool covers the
complete selection path with these commands in place.

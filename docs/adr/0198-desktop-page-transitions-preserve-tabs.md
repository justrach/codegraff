# 0198. Desktop page transitions preserve chat references

Status: accepted 2026-09-24

## Context

A desktop reload or update restart destroys the renderer and its per-chat ACP
processes. Saved conversations can be reopened, but the open tabs and their
selection existed only in renderer memory. An active turn could be interrupted
without a decision from the user (#1237).

## Decision

Persist the open tab session names, workspaces, order, split groups, and active
tab in the desktop browser store. On a new page, rebuild those tabs and read
their saved transcripts from the session store. A restored tab may resume its
ACP session in its original workspace on the next prompt; replayed transcript
rows do not rerun tools. Do not persist live transcript text, tool state, or
drafts in the tab record.

Before a user reloads or restarts for an update with active turns, confirm that
the turns will be interrupted. Page unload still reaps the old page's agents.

## Consequences

The browser record can restore navigation even when one checkpoint is missing.
Work after the last engine checkpoint may be lost when an active turn is
interrupted. Closing the page does not make its agents detached workers.

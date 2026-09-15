# 0128. GUI context meter uses harness occupancy

Status: accepted

## Decision

The composer displays approximate remaining context from the harness occupancy
and effective window reported through ACP. It never infers occupancy from total
billed tokens, cache hits, or a model catalog default. The reading is explicitly
last reported; missing or invalid data stays unknown. Slash commands refresh the
reading so compaction and model changes do not leave their previous value shown.

The ring stays compact, with token detail available on hover or focus. Over-cap
readings clamp remaining capacity to zero. Saved snapshots are not live meters.

## Validation

Protocol and reducer tests cover occupancy delivery, compaction, missing values
and over-cap readings. The production GUI fixture compares the displayed reading
with the real saved harness context and checks the visible detail panel.

# Desktop visual tests

From `apps/native`, run `bun run build`, then `bun run test:visual`.
This opens an isolated Electron window, renders scripted turn states, and
checks visible progress, layout, disclosure state, completion and interruption
in White, Black and CodeGraff themes. PNGs and results go to
`zig-out/visual-tests`; set `GRAFF_VISUAL_OUTPUT` to use another directory.

No engine binary, model account, MCP server or model request is used. Requests
to API routes are blocked and fail the test. The fixture page is unavailable
unless the test server sets `GRAFF_VISUAL_TESTS=1`. Tests use the production
transcript components, with deterministic input data rather than model output.

`bun run test:desktop` also covers transport parsing, turn-state decisions and
the deferred-render race. The packaged Electron smoke suite exercises the
composer and scripted streaming path in addition to its engine integration.

## Repeatable performance and README captures

`bun run test:performance` runs the visual suite followed by a synthetic full-GUI
workload: startup, a reply, Appearance changes, review, and a longer streamed
transcript. It writes `performance.json` and `desktop-*.png` beside the visual
results. Its fetch adapter supplies fixed demonstration content before hydration;
the runner blocks any API request that escapes the adapter. No credentials,
workspace contents, engine process or model is needed.

The baseline phase covers startup and controls; the candidate phase covers
streaming. These are different workloads, **not** an optimization A/B result.
Compare the same phase across repeated runs on the same machine and app build.
The test window disables background throttling to make off-focus test runs
reliable; the normal application still throttles hidden windows. Run visual
runners one at a time, without rebuilding the UI during a run.

The profile includes document LCP/FCP, peak observed interaction duration, summed
layout shift during recording, renderer JS heap/DOM size, process-tree RSS/CPU,
main-loop delay and GPU-process CPU/RSS. LCP is a startup metric; it does not
measure streamed replies. Scripted `.click()` calls are not trusted user input
and may produce no Event Timing samples. Missing values stay null. This report
is neither a Lighthouse score nor field INP/CLS. GPU utilization/VRAM are not
available through these metrics; GPU-process memory overlaps process-tree RSS.

For a live agent-driven profile, use the desktop `profiler` tool's `start`,
`mark` (baseline/candidate), `report` and `stop` operations. Reload the window
while recording to collect fresh startup timings, then reproduce the same
interaction in each phase. Observers and samples stop when recording stops;
recording is off by default and capped at ten minutes. Export via the Performance
menu when a local feedback artifact is wanted.

To refresh the README, inspect the synthetic `desktop-*.png` files, then copy
selected captures into `docs/images`. Keep test reports and real-user screenshots
out of public documentation.

# Desktop visual tests

From `apps/native`, run `bun run build`, then `bun run test:visual`.
This renders scripted turn states in hidden, isolated Electron windows and
checks visible progress, layout, disclosure state, completion and interruption
in White, Black and CodeGraff themes. PNGs and results go to
`zig-out/visual-tests`; set `GRAFF_VISUAL_OUTPUT` to use another directory.

All visual suites, standalone GUI coding trials, packaged smoke checks and
benchmarks use the shared background window policy. Tests keep the user's active
application focused; creating, switching or cleaning up fixtures does not show
or activate windows. Page input uses Chromium's trusted input path, including
real Tab navigation, without sending keyboard or mouse events to the desktop.

On macOS the visual and benchmark launchers start a read-only OS observer before
Electron. Any activation or visible test window fails the run. The observer needs
the Xcode command-line tools and requests no Accessibility or screen-capture
permission. `bun run test:background` exercises the policy without a UI build:
repeated windows, trusted input, screenshots, rejected activation and cleanup.
The same background regression runs automatically before default visual suites.
`bun run test:desktop` checks that future fixtures use the shared policy.

Native fullscreen, native computer input and native sheets require explicit
opt-in: `GRAFF_TEST_FOREGROUND=1 bun run test:visual`. These checks may activate
windows and change macOS Spaces. Default reports identify them as not run.
The foreground option also applies to packaged smoke checks and benchmarks;
`GRAFF_SMOKE_SKIP_INPUT=1` still disables native computer input in foreground mode.

No engine binary, model account, MCP server or model request is used. Requests
to API routes are blocked and fail the test. The fixture page is unavailable
unless the test server sets `GRAFF_VISUAL_TESTS=1`. Tests use the production
transcript components, with deterministic input data rather than model output.

`bun run test:desktop` also covers transport parsing, turn-state decisions and
the deferred-render race. The packaged Electron smoke suite exercises the
composer and scripted streaming path in addition to its engine integration.

`bun run test:interactions` runs the keyboard, composer, Files and first-reply
scrolling regressions on their own. It exercises actual mouse and Tab input,
per-chat drafts, delayed uploads, request failures and late responses. These
checks also run in the full visual suite and the Projects suite.

## Repeatable performance and README captures

### Comparing production builds

Build and preserve the baseline before editing, then build the candidate. Run
the same benchmark against each package directory, one window at a time:

```sh
bun run benchmark:desktop /absolute/baseline/apps/native /absolute/local-results/baseline
bun run benchmark:desktop /absolute/candidate/apps/native /absolute/local-results/candidate
```

The runner creates a fresh profile and uses synthetic code fences, mermaid diagrams, long prose,
and trusted wheel input. It measures renderer heap after collection, summed
process RSS, script/layout work and frame callback intervals. Repeat both runs
and compare matching scenarios in the same window mode. The default background
mode disables throttling so hidden pages keep rendering. Reports record the mode.
For display/presentation measurements, explicitly use `GRAFF_TEST_FOREGROUND=1`
for both runs and keep the windows on the same display; that mode retains
production throttling. Both modes retain Chromium hardware acceleration.
RSS includes shared pages and is not an exclusive physical-memory measurement.

Set `GRAFF_BENCHMARK_TRACE=scroll`, `code`, or `mermaid` for a separate local Chromium trace.
Tracing adds memory overhead, so use untraced runs for RAM comparisons. Frame
callbacks measure scheduling; verify presentation from trace display-feedback
and sequence counters before making refresh-rate claims. Keep reports and raw
traces local. The library-only memory checks are
`node scripts/benchmark-code-memory.mjs` and
`node scripts/benchmark-session-memory.mjs`; they do not measure the whole app.

### Capturing the demonstration gallery

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

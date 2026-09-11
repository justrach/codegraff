# Desktop visual tests

## Native CI coverage

The desktop workflow keeps the background suite and adds a separate `macos-26`
job with `GRAFF_ELECTRON_FOREGROUND=1`. It runs on pull requests and pushes to
`main` and release branches. Its windows and fullscreen transitions belong to
the CI machine's desktop, not the developer's desktop.

`bun run test:native` compiles the production Activity/Computer Use bridge and
a test-only AppKit observer. It requires a usable display and native window
focus, then opens, dismisses with Return, and reopens the real SwiftUI Activity
sheet. The foreground visual suite separately verifies fullscreen entry,
reload, titlebar state and fullscreen exit. Missing reports or skipped fullscreen
coverage fail `check-native-ci.mjs`.

Native OS typing/Accessibility inspection and display capture require macOS
permissions. The native runner does not request or change them. It runs each
available check and records missing permissions as skips in the job summary
and `native-results.json`; they are never reported as passed. On a runner with
preconfigured permissions, `GRAFF_NATIVE_REQUIRE_OS_INPUT=1` makes them required.

For compilation without opening windows, run
`bun scripts/test-native.mjs --build-only`. Running `test:native` locally without
explicit foreground opt-in fails before Electron starts.

For a fresh checkout, run these from `apps/native`:

```sh
bun install --frozen-lockfile
bun node_modules/electron/install.js
bun run build
bun run test:visual
```

The explicit Electron install also works when Bun skips dependency postinstall scripts.
This renders scripted turn states in hidden, non-focusable Electron windows and
checks visible progress, layout, disclosure state, completion and interruption
in White, Black and CodeGraff themes. PNGs and results go to
`zig-out/visual-tests`; `test-run.json` records the mode, result and skipped checks. Set `GRAFF_VISUAL_OUTPUT` to use another directory.

All visual suites, standalone GUI coding trials, packaged smoke checks and
benchmarks share the window policy. Page input uses Chromium's trusted input
path without sending keyboard or mouse events to the desktop.

On macOS visual and benchmark launchers start a read-only OS observer before
Electron. Unexpected activation fails the run; hidden mode also rejects visible
windows. The observer requires the Xcode command-line tools.
`bun run test:background` checks repeated hidden windows, trusted input,
screenshots and cleanup without a UI build. It also runs before hidden visual suites.
`GRAFF_TEST_FOREGROUND=1` remains an alias for the explicit foreground mode below.

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

## Desktop focus and native coverage (#832)

The visual, benchmark, coding-smoke and packaged-smoke entry points install the
same hidden-window policy before Electron becomes ready. Default runs never
request foreground activation. No environment flag is needed for this default.
Test constructor overrides cannot enable showing/focus, and unexpected native
activation calls fail the run. Errors never retry by bringing a window forward.

On macOS, verify the real process while continuing to use another application:

```sh
bun run test:focus
bun run test:focus node_modules/.bin/electron electron/test-window-probe.cjs
bun run test:tagged
```

The focus observer requires Xcode command-line tools. It observes activation,
visible windows and cleanup; it neither switches applications nor injects input.
Switching applications during a run is allowed. The output reports how many
such switches were observed; zero means that particular scenario was not tested.
The observer currently supports macOS only.

Some checks need a visible window. Default hidden runs explicitly skip embedded
browser pin input/captures and native fullscreen. Packaged smoke tests
also skip OS keyboard injection/screen capture and the native Activity sheet.
These skips are coverage limits, not passes. A hidden WebContentsView did not
accept the pin-input sequence reliably, including through DevTools input. A
visible inactive host does support those browser checks without taking focus.
**Visible windows can still cover your current app.** Keep the default hidden
mode when tests must stay out of the way; visible mode is for watching tests:

```sh
GRAFF_ELECTRON_VISIBLE=1 bun run test:browser
GRAFF_ELECTRON_VISIBLE=1 bun run test:focus
```

This mode prohibits macOS app activation as well as window focus. A window-only
restriction was insufficient because focusing embedded web contents could still
activate the app. The observer allows visible windows in this mode but still
fails on any app activation or leftover test app.

These commands **can take desktop focus** and are explicit opt-ins:

```sh
GRAFF_ELECTRON_FOREGROUND=1 bun run test:visual
```

`GRAFF_ELECTRON_VISIBLE=1` does not enable OS keyboard injection, native
fullscreen or Activity sheets. For packaged smoke runs the same foreground
flag is required before any OS input; `GRAFF_SMOKE_SKIP_INPUT=1` still disables
that input even in foreground mode. OS permissions alone never opt in.

## Repeatable performance and README captures

### Comparing production builds

Build and preserve the baseline before editing, then build the candidate. Run
the same benchmark against each package directory, one window at a time:

```sh
bun run benchmark:desktop /absolute/baseline/apps/native /absolute/local-results/baseline
bun run benchmark:desktop /absolute/candidate/apps/native /absolute/local-results/candidate
```

The runner creates a fresh profile and uses synthetic code fences, mermaid diagrams, long prose,
and Chromium wheel input. It measures renderer heap after collection, summed
process RSS, script/layout work and frame callback intervals. Repeat both runs
and compare matching scenarios. Hidden runs disable background throttling and retain hardware acceleration.
For presentation measurements explicitly opt into foreground mode on the same
display; hidden results do not establish on-screen refresh or native focus behavior.
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

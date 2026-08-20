# graff-kernel.wasm

The ToolCatalog cube and the lexical path jail, compiled to
`wasm32-freestanding`. This is **not** the agent. fx's `fx-core.wasm` is a
host-supplied ACP loop (JSPI fetch, no bash). graff's first wasm artifact is
the same finite functions Lean proves — 64 catalog cells, `confined(path)`.

See [ADR 0012](../../docs/adr/0012-wasm-is-the-kernel-cube.md).

## Build

```sh
zig build wasm
# zig-out/bin/graff-kernel.wasm
```

ReleaseSmall is the default even on a Debug configure: the kernels have
nothing to debug in DWARF, and a Debug wasm is mostly unused panic
machinery.

## Use

```js
import { loadGraffKernel } from "./graff-kernel.js";

const k = await loadGraffKernel("./graff-kernel.wasm");
k.cubeCells();                          // 64
k.catalog();                            // ["bash", "bash_output", ...]
k.catalog({ lean: true });              // 8 names
k.advertised("subagent", { isSub: true }); // false
k.confined("/etc/passwd");              // false
k.confined("src/main.zig");             // true
```

Flag bits: `noLocal`, `lean`, `imagegen`, `clockSleep`, `learnLoaded`, `isSub`.

No JSPI. A later `graff-core.wasm` that talks to a model will need a host
`fetch` (and must not pretend bash exists). Until then, embed the live
harness with `graff serve` and the remote SDK.

## Demo

After `zig build wasm`, from the repo root:

```sh
python3 -m http.server 8080
# open http://localhost:8080/sdk/wasm/demo.html
```

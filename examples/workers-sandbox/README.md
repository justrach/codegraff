# Worker-native Graff with Codegraff sandboxes

A Durable Object owns a task, Graff's Zig/Wasm chat step owns the model/tool loop,
and an existing Codegraff cloud VM executes shell commands. This does not move
the agent into the VM or require a new Docker/Cloudflare Container installation.

A DO can coordinate difficult tasks, retain state, and await model and tool
calls. It cannot itself spawn Linux processes. That execution capability is
provided here by Codegraff's documented sandbox HTTP API.

## Live coding test

This is an **opt-in, billed integration test**: real inference and a real,
disposable fleet sandbox. It sends only a synthetic Python repair task, never
local repository files or user data.

```sh
# Repository root; Zig 0.17.0 and Node 22+.
zig build wasm-worker
cd examples/workers-sandbox
npm ci
npm run typecheck
# Set CODEGRAFF_API_KEY securely in the environment, then:
npm run test:live
```

The example defaults to `ultramarine-1-flash` (Ultramarine 1 Flash). The live test asserts that every outgoing
model request uses that exact configured alias; it never substitutes another
model. Set `GRAFF_SANDBOX_TEST_MODEL` explicitly to test a different configured
model.

The test starts cf/workerd and an authenticated loopback bridge. The real key
stays in the bridge process's memory; it is removed from cf's child environment
and never written to configuration, Wasm memory or the sandbox. No secret file
is created. The bridge allows only model calls and operations on VMs this test
created, and stops when the test ends.

The Durable Object:

1. Creates an isolated Codegraff fleet VM with a bounded lease.
2. Uploads a deliberately broken interval-subtraction module and independent tests.
3. Confirms the original implementation fails and that model/ingress credentials
   are absent from the VM environment.
4. Runs the real model through Graff's WASM core. `sandbox_exec` lets it inspect,
   edit and test the module in the VM.
5. Independently verifies unchanged tests, a changed implementation, named edge
   cases and 2,000 deterministic randomized comparisons against an integer-set
   oracle. A model's claim of success is not sufficient.
6. Deletes the VM. A recorded VM ID and DO alarm provide backup cleanup if the
   request is interrupted; the short VM lease is a further bound.

Output contains the synthetic result, verification and aggregate call counts,
not credentials or sandbox identifiers. No hosted Worker is deployed by the test.

## Hosting the example

Supply `CODEGRAFF_API_KEY` and `INGRESS_TOKEN` using Cloudflare secrets, choose
`MODEL_NAME`, and use `cf deploy --dry-run` before deploying. Do not set
`GRAFF_SANDBOX_TEST_BRIDGE` outside the local test. Ingress requires an authenticated
POST before allocating a task or spending credits. The endpoint runs the fixed
repair fixture; it is not a general-purpose unauthenticated command service.

`SandboxTask` is an actual Durable Object. Its storage currently records only
cleanup ownership, not a resumable conversation. Every request receives a new
task/VM; overlapping callers cannot share workspaces. Codegraff API credentials
remain in the Worker host; the VM is never given those credentials.

The fetch-only client is `@codegraff/sdk/worker-sandbox`. It uses the public
[Codegraff sandbox API](https://codegraff.com/docs/sandboxes), bounds request
and response sizes, has no automatic effect retries, and supports independent
cleanup after task cancellation. Aborting HTTP does not prove a remote command
stopped; VM destruction is the execution boundary. The test is not an adversarial
audit of the VM provider's isolation.

This builds on the experimental Worker-native core's current limitations:
nonstreaming Chat Completions, bounded host tools, and no full native CLI parity.
Long-lived sessions, workspace snapshots, resumable turns and longer asynchronous
sandbox jobs remain separate capabilities.

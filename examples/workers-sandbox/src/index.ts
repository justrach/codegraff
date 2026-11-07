import { DurableObject } from "cloudflare:workers";
import { createWorkerAgent, type WorkerTool } from "../../../sdk/ts/worker.ts";
import { createCodegraffSandbox, attachCodegraffSandbox, SandboxError } from "../../../sdk/ts/worker-sandbox.ts";
import module from "../../../zig-out/bin/graff-worker.wasm?module";
import { implementation, tests, task } from "./fixture.ts";

type Env = {
  TASKS: DurableObjectNamespace<SandboxTask>;
  CODEGRAFF_API_KEY?: string;
  INGRESS_TOKEN?: string;
  MODEL_NAME: string;
  TEST_BRIDGE: string;
};
const gateway = "https://gateway.codegraff.com";
const workspace = "/tmp/graff-task";
function capabilities(env: Env) {
  const bridge = env.TEST_BRIDGE;
  if (bridge && !/^http:\/\/127\.0\.0\.1:\d+$/.test(bridge)) throw new Error("Invalid test bridge");
  const transport: typeof fetch = bridge ? (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.origin !== gateway) throw new Error("Unexpected upstream");
    return fetch(`${bridge}${url.pathname}${url.search}`, init);
  } : fetch;
  return { token: bridge ? "cg_sk_local_live_test_placeholder" : env.CODEGRAFF_API_KEY ?? "", fetch: transport };
}
function safeError(error: unknown): string {
  // Only locally defined error class names, never provider bodies or headers.
  return error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,60}$/.test(error.name) ? error.name : "TaskFailed";
}

/** DO owns task coordination; the WASM core makes decisions; the VM runs code. */
export class SandboxTask extends DurableObject<Env> {
  async alarm() {
    const id = await this.ctx.storage.get<string>("sandboxId");
    if (id) await attachCodegraffSandbox(id, capabilities(this.env)).destroy();
    await this.ctx.storage.deleteAll();
  }

  override async fetch(request: Request): Promise<Response> {
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(180_000)]);
    let sandbox: Awaited<ReturnType<typeof createCodegraffSandbox>> | undefined;
    let phase = "create";
    let report: Record<string, unknown> = { ok: false };
    let cleaned = false;
    try {
      sandbox = await createCodegraffSandbox({ ...capabilities(this.env), signal, autoStopMinutes: 5 });
      await this.ctx.storage.put("sandboxId", sandbox.id);
      // Backup after a disconnected/terminated request; lease is a second bound.
      await this.ctx.storage.setAlarm(Date.now() + 240_000);
      phase = "bootstrap";
      const mkdir = await sandbox.exec(`mkdir -p ${workspace}`, { signal });
      if (mkdir.exitCode !== 0) throw new Error("Workspace initialization failed");
      await sandbox.upload(`${workspace}/intervals.py`, implementation, { signal });
      await sandbox.upload(`${workspace}/test_intervals.py`, tests, { signal });
      const secrets = await sandbox.exec("python3 -c 'import os; assert not any(os.environ.get(k) for k in (\"CODEGRAFF_API_KEY\", \"MODEL_TOKEN\", \"INGRESS_TOKEN\")); print(\"credentials absent\")'", { signal });
      if (secrets.exitCode !== 0) throw new Error("Credential isolation failed");
      phase = "baseline";
      const baseline = await sandbox.exec("python3 test_intervals.py", { cwd: workspace, signal });
      if (baseline.exitCode === 0) throw new Error("Fixture was not initially broken");
      let dispatched = 0;
      const tool: WorkerTool = {
        name: "sandbox_exec",
        description: "Execute a shell command in the task's isolated Codegraff VM at /tmp/graff-task. Returns exitCode and result; timeout 30 seconds. No host filesystem or credentials.",
        parameters: { type: "object", properties: { command: { type: "string", maxLength: 8192 } }, required: ["command"], additionalProperties: false },
        validate: input => !!input && typeof input === "object" && !Array.isArray(input) && Object.keys(input).length === 1 &&
          typeof (input as { command?: unknown }).command === "string" && (input as { command: string }).command.length > 0 && (input as { command: string }).command.length <= 8192,
        async execute(input, { signal: toolSignal }) {
          dispatched++;
          return JSON.stringify(await sandbox!.exec((input as { command: string }).command, { cwd: workspace, signal: toolSignal, timeoutSeconds: 30 }));
        },
      };
      phase = "agent";
      const host = capabilities(this.env);
      const agent = await createWorkerAgent(module, {
        endpoint: `${gateway}/v1/chat/completions`, model: this.env.MODEL_NAME,
        token: host.token, fetch: host.fetch, maxSteps: 8, tools: [tool],
        instructions: "Repair the provided synthetic Python module using sandbox_exec. Treat nonzero exits as failures to diagnose. Never modify the tests. Run the tests successfully before your final answer. Keep commands and output short.",
      });
      const result = await agent.prompt(task, { signal });
      phase = "verify";
      const unchanged = await sandbox.download(`${workspace}/test_intervals.py`, { signal }) === tests;
      const verification = await sandbox.exec("python3 test_intervals.py", { cwd: workspace, signal });
      const repaired = await sandbox.download(`${workspace}/intervals.py`, { signal });
      const passed = dispatched > 0 && unchanged && verification.exitCode === 0 && verification.result.includes("RANDOMIZED_CASES=2000") && repaired !== implementation;
      report = { ok: passed, model: this.env.MODEL_NAME, ...result, sandboxToolCalls: dispatched, baselineFailed: true, testsUnchanged: unchanged,
        verification: { exitCode: verification.exitCode, result: verification.result }, credentialIsolation: true, implementation: repaired };
    } catch (error) {
      report = { ok: false, phase, error: safeError(error),
        code: error instanceof SandboxError ? error.code : undefined,
        status: error instanceof SandboxError ? error.status : undefined };
    } finally {
      if (sandbox) {
        try {
          // Independent deadline: cleanup must still work after task cancellation.
          await sandbox.destroy();
          cleaned = true;
          await this.ctx.storage.deleteAlarm();
          await this.ctx.storage.deleteAll();
        } catch { /* Durable alarm retries cleanup; idle lease also bounds billing. */ }
      }
    }
    return Response.json({ ...report, sandboxDestroyed: cleaned }, { status: report.ok && cleaned ? 200 : 500 });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") return new Response("Use POST", { status: 405 });
    if (!env.TEST_BRIDGE) {
      if (!env.INGRESS_TOKEN || request.headers.get("authorization") !== `Bearer ${env.INGRESS_TOKEN}`) return new Response("Unauthorized", { status: 401 });
      if (!env.CODEGRAFF_API_KEY) return new Response("Sandbox key is not configured", { status: 503 });
    }
    // Fresh task identity: requests never share a workspace or uncertain effects.
    return env.TASKS.get(env.TASKS.idFromName(crypto.randomUUID())).fetch(request);
  },
} satisfies ExportedHandler<Env>;

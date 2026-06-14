// Proof the remote SDK runs inside the Workers runtime (workerd): no node:
// imports, fetch + Web Streams only. src/remote.ts is a copy of
// sdk/ts/remote.ts — in a real project, `npm install @graff-new/sdk` and
// `import { ... } from "@graff-new/sdk/remote"` instead.
import { RemoteHarness, runAgentRemote, HARNESS_VERSION } from "./remote";

interface Env {
  BRIDGE_URL: string;
  BRIDGE_TOKEN?: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = env.BRIDGE_URL;
    const token = env.BRIDGE_TOKEN ?? "edge-test";
    const prompt = new URL(req.url).searchParams.get("q");

    // ?q=...: stream a one-shot turn straight through to the HTTP response.
    if (prompt) {
      const events = runAgentRemote({ url, token, yolo: true, prompt });
      const stream = new ReadableStream({
        async pull(controller) {
          const { done, value } = await events.next();
          if (done) return controller.close();
          controller.enqueue(new TextEncoder().encode(JSON.stringify(value) + "\n"));
        },
      });
      return new Response(stream, { headers: { "content-type": "application/x-ndjson" } });
    }

    // Default: a multi-turn session + a tool-using one-shot, summarized.
    const h = RemoteHarness.init({ url, token, yolo: true });
    const answer = await h.ask("what is 6*7? just the number");
    await h.close();
    const seen: string[] = [];
    let final = "";
    for await (const ev of runAgentRemote({ url, token, yolo: true, prompt: "run: echo from-workers" })) {
      seen.push(ev.type);
      if (ev.type === "turn") final = ev.text;
    }
    return Response.json({ ok: true, sdk: HARNESS_VERSION, answer, events: seen, final });
  },
};

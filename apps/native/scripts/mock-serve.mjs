#!/usr/bin/env node
/** Offline stand-in for `graff serve` so the UI can be exercised without a
 *  provider key. Speaks the same /healthz + /v1/sessions NDJSON contract. */
import http from "node:http";

const PORT = Number(process.env.PORT ?? 8787);

function ndjson(res, events) {
  res.writeHead(200, {
    "content-type": "application/x-ndjson",
    "cache-control": "no-store",
  });
  for (const ev of events) res.write(`${JSON.stringify(ev)}\n`);
  res.end();
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);
  if (req.method === "GET" && url.pathname === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", mock: true }));
    return;
  }
  if (req.method === "POST" && url.pathname === "/v1/sessions") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ session_id: "mock000000000001", resumed: false, last_seq: 0 }));
    return;
  }
  const session = url.pathname.match(/^\/v1\/sessions\/([^/]+)$/);
  if (session && req.method === "POST") {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw || "{}");
    } catch {
      body = {};
    }
    if (body.type === "answer" || body.type === "cancel") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    if (body.type === "set_model") {
      ndjson(res, [{ seq: 1, type: "model", ok: true, provider: "mock", model: body.model ?? "gpt-5.5", context: 0, note: "" }]);
      return;
    }
    const prompt = String(body.text ?? "");
    ndjson(res, [
      { seq: 1, type: "started", provider: "mock", model: "gpt-5.5" },
      { seq: 2, type: "reasoning", text: "I'll inspect the workspace, then answer." },
      {
        seq: 3,
        type: "tool_call",
        name: "read_file",
        input: { path: "README.md" },
      },
      { seq: 4, type: "tool_result", name: "read_file", is_error: false, text: "# codegraff\nZig coding harness" },
      { seq: 5, type: "text", text: `Heard: ${prompt || "(empty)"}\n\n` },
      { seq: 6, type: "text", text: "This is a mock graff serve stream. Point GRAFF_SERVE_URL at a real `graff serve` for the live agent." },
      { seq: 7, type: "turn", text: "", context_tokens: 12, cost_usd: 0, input_tokens: 0, uncached_input_tokens: 0, cache_read_tokens: 0, output_tokens: 0, api_calls: 0, subscription_calls: 0, unpriced_calls: 0 },
    ]);
    return;
  }
  if (session && req.method === "DELETE") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`mock graff serve on http://127.0.0.1:${PORT}`);
});

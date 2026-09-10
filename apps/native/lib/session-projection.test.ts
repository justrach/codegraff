import { test, expect } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { GET } from "../app/api/sessions/route";
import { loadSession, sessionFromResponse, transcriptFromMessages } from "./sessions";
import { withGuiSkillContext } from "./gui-skills";

const raw = [
  { role: "system", content: "Not conversation text" },
  { role: "user", content: [{ type: "text", text: withGuiSkillContext("Inspect the file 世界", "hidden instructions") }, { type: "image", data: "pixels".repeat(10_000) }] },
  { type: "function_call", call_id: "read", name: "read_file", arguments: '{"path":"file.txt"}' },
  { type: "function_call_output", call_id: "read", output: "File contents\n" + "large body\n".repeat(10_000) },
  { type: "function_call", call_id: "done", name: "attempt_completion", arguments: '{"result":"Read it."}' },
  { role: "user", content: "Run the check" },
  { role: "assistant", content: "Checking.", tool_calls: [
    { id: "run", function: { name: "bash", arguments: '{"command":"check"}' } },
    { id: "todo", function: { name: "todo_write", arguments: '{"todos":[{"content":"Review","status":"in_progress"}]}' } },
  ] },
  { role: "tool", tool_call_id: "run", content: "Error: check failed\nfull diagnostics" },
  { role: "assistant", content: "The check needs attention." },
];

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), "graff-session-projection-"));
  const folder = path.join(root, ".graff/sessions"); mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, "example.session.json"), JSON.stringify({ title: "Example", model: "demo", updated_ms: 100, messages: raw }));
  const url = (view?: string) => `http://localhost/api/sessions?${new URLSearchParams({ root, name: "example", ...(view ? { view } : {}) })}`;
  return { root, url, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

test("legacy title recovery agrees across list, search, raw and projected session views (#830)", async () => {
  const file = fixture();
  const messages = [
    { role: "user", content: [{ type: "input_text", text: "[peer] wake" }] },
    { role: "user", content: [{ type: "input_image", image_url: "data:image/png;base64,AA==" }] },
    { role: "user", content: [{ type: "input_text", text: "Repair the sidebar label" }] },
    { role: "assistant", content: "The fix is ready." },
  ];
  try {
    for (const title of ["Untitled session", "My chosen label"]) {
      writeFileSync(path.join(file.root, ".graff/sessions/example.session.json"), JSON.stringify({ title, model: "demo", updated_ms: 200, messages }));
      const expected = title === "Untitled session" ? "Repair the sidebar label" : title;
      const listUrl = new URL(file.url()); listUrl.searchParams.delete("name");
      listUrl.searchParams.set("scope", "local"); listUrl.searchParams.set("q", expected);
      const listing = await (await GET(new NextRequest(listUrl))).json();
      expect(listing.sessions.find((row: { name: string }) => row.name === "example")?.title).toBe(expected);
      for (const view of [undefined, "transcript"]) {
        const response = await GET(new NextRequest(file.url(view)));
        expect(response.status).toBe(200);
        const body = await response.json();
        expect(body.title).toBe(expected);
        expect(body.updatedMs).toBe(200);
        if (view) expect(body.transcript).toEqual(transcriptFromMessages(messages, "demo"));
        else expect(body.messages).toEqual(messages);
      }
    }
  } finally { file.cleanup(); }
});

test("only an explicit transcript request projects raw history; the default API stays unchanged", async () => {
  const file = fixture();
  try {
    for (const view of [undefined, "raw", "unknown"]) {
      const response = await GET(new NextRequest(file.url(view)));
      expect(response.status).toBe(200);
      const body = await response.json();
      expect(body.messages).toEqual(raw);
      expect(body.presentation).toBeUndefined(); expect(body.transcript).toBeUndefined();
    }
    const response = await GET(new NextRequest(file.url("transcript")));
    const body = await response.json();
    expect(body.messages).toBeUndefined(); expect(body.presentation).toBe("transcript-v1");
    expect(body.transcript).toEqual(transcriptFromMessages(raw, "demo"));
    expect(JSON.stringify(body)).not.toContain("hidden instructions");
    expect(JSON.stringify(body)).not.toContain("large body");
    expect(JSON.stringify(body).length).toBeLessThan(JSON.stringify(raw).length / 20);
  } finally { file.cleanup(); }
});

test("projected and legacy responses restore exactly the same visible conversation and metadata", async () => {
  const file = fixture();
  try {
    const legacy = await (await GET(new NextRequest(file.url()))).json();
    const projected = await (await GET(new NextRequest(file.url("transcript")))).json();
    expect(sessionFromResponse(projected)).toEqual(sessionFromResponse(legacy));
    const loaded = sessionFromResponse(projected);
    expect(loaded.messages.length).toBe(4);
    expect("presentation" in loaded.meta).toBe(false); expect("transcript" in loaded.meta).toBe(false);
  } finally { file.cleanup(); }
});

test("the client requests projection and propagates cancellation while accepting legacy UI fixtures", async () => {
  const file = fixture(), previous = globalThis.fetch;
  const controller = new AbortController();
  try {
    for (const legacy of [false, true]) {
      let requested = false;
      globalThis.fetch = (async (input, init) => {
        const url = new URL(String(input), "http://localhost");
        expect(url.searchParams.get("view")).toBe("transcript");
        expect(url.searchParams.get("name")).toBe("example");
        expect(init?.signal).toBe(controller.signal); expect(init?.cache).toBe("no-store");
        requested = true;
        if (legacy) url.searchParams.delete("view");
        return GET(new NextRequest(url));
      }) as typeof fetch;
      const loaded = await loadSession("example", file.root, controller.signal);
      expect(requested).toBe(true); expect(loaded.messages).toEqual(transcriptFromMessages(raw, "demo"));
    }
  } finally { globalThis.fetch = previous; file.cleanup(); }
});

test("the projected client keeps empty legacy histories and server failures readable", async () => {
  expect(sessionFromResponse({ name: "empty", title: null, model: null, provider: null, updatedMs: 0, size: 0 }).messages).toEqual([]);
  const previous = globalThis.fetch;
  try {
    globalThis.fetch = (async () => new Response("Temporarily unavailable", { status: 503 })) as typeof fetch;
    await expect(loadSession("example")).rejects.toThrow("503: Temporarily unavailable");
  } finally { globalThis.fetch = previous; }
});

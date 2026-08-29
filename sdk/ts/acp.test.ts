import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { acp, ACP_PROTOCOL_VERSION, spawnAcp, type AcpConn, type AcpUpdate } from "./acp.ts";

const fixture = join(import.meta.dir, "test-fixtures", "fake-acp.mjs");
const live: AcpConn[] = [];
const command = [process.execPath, fixture];

const deadline = <T>(promise: Promise<T>, ms = 2_000): Promise<T> =>
  Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error("test timed out")), ms)),
  ]);

afterEach(async () => {
  await Promise.all(live.splice(0).map((c) => c.close()));
});

describe("spawnAcp / acp", () => {
  test("handshake is initialize → session/new, then prompt streams session/update", async () => {
    const conn = spawnAcp({ command });
    live.push(conn);
    const commands = new Promise<AcpUpdate>((resolve) => {
      const off = conn.onUpdate((update) => {
        if (update.sessionUpdate === "available_commands_update") {
          off();
          resolve(update);
        }
      });
    });
    await deadline(
      conn.request("initialize", {
        protocolVersion: ACP_PROTOCOL_VERSION,
        clientCapabilities: { fs: {} },
      }),
    );
    const created = (await deadline(conn.request("session/new", { cwd: "/tmp" }))) as { sessionId: string };
    expect(created.sessionId).toBe("acp-test-1");
    conn.sessionId = created.sessionId;
    expect((await deadline(commands)).sessionUpdate).toBe("available_commands_update");

    const { stopReason, updates } = await deadline(conn.prompt("hello"));
    expect(stopReason).toBe("end_turn");
    expect(updates.map((u) => u.sessionUpdate)).toEqual([
      "agent_thought_chunk",
      "tool_call",
      "tool_call_update",
      "agent_message_chunk",
    ]);
    const text = updates.find((u) => u.sessionUpdate === "agent_message_chunk");
    expect((text?.content as { text?: string } | undefined)?.text).toBe("echo:hello");
  });

  test("acp() runs the handshake and fills sessionId", async () => {
    const conn = await deadline(acp({ command }));
    live.push(conn);
    expect(conn.sessionId).toBe("acp-test-1");
  });

  test("request sends real ACP method names and surfaces JSON-RPC errors", async () => {
    const conn = spawnAcp({ command });
    live.push(conn);
    const init = (await deadline(
      conn.request("initialize", { protocolVersion: ACP_PROTOCOL_VERSION, clientCapabilities: { fs: {} } }),
    )) as { protocolVersion: number; agentImplementation: { name: string } };
    expect(init.protocolVersion).toBe(1);
    expect(init.agentImplementation.name).toBe("graff");

    await expect(deadline(conn.request("session/load", { sessionId: "nope" }))).rejects.toThrow(
      "method not found: session/load",
    );
    await expect(deadline(conn.request("session/prompt", { prompt: [{ type: "text", text: "die" }] }))).rejects.toThrow(
      "boom",
    );
  });

  test("session/cancel is a notify", async () => {
    const conn = spawnAcp({ command });
    live.push(conn);
    conn.notify("session/cancel", { sessionId: "acp-test-1" });
    const created = (await deadline(conn.request("session/new", { cwd: "/tmp" }))) as { sessionId: string };
    expect(created.sessionId).toBe("acp-test-1");
  });
});

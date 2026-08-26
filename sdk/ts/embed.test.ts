import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { ACP_PROTOCOL_VERSION } from "./acp.ts";
import { createGraffAgent, graffAgent } from "./embed.ts";

const wasmPath = process.env.GRAFF_CORE_WASM ?? join(import.meta.dir, "../../zig-out/bin/graff-core.wasm");
const haveWasm = existsSync(wasmPath);

describe("createGraffAgent", () => {
  test.skipIf(!haveWasm)("handshake and echo prompt run in-process", async () => {
    const agent = await createGraffAgent({ wasm: wasmPath, seed: 0xabc });
    const init = (await agent.request("initialize", {
      protocolVersion: ACP_PROTOCOL_VERSION,
      clientCapabilities: { fs: {} },
    })) as { protocolVersion: number; agentImplementation: { name: string } };
    expect(init.protocolVersion).toBe(1);
    expect(init.agentImplementation.name).toBe("graff");

    const created = (await agent.request("session/new", { cwd: "/tmp" })) as { sessionId: string };
    expect(created.sessionId).toBe("acp-abc-1");
    agent.sessionId = created.sessionId;

    const { stopReason, updates } = await agent.prompt("ping");
    expect(stopReason).toBe("end_turn");
    const text = updates.find((u) => u.sessionUpdate === "agent_message_chunk");
    expect((text?.content as { text?: string } | undefined)?.text).toBe("echo:ping");
  });

  test.skipIf(!haveWasm)("graffAgent() fills sessionId", async () => {
    const agent = await graffAgent({ wasm: wasmPath, seed: 0xabc, cwd: "/tmp" });
    expect(agent.sessionId).toBe("acp-abc-1");
  });
});

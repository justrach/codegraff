import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { retireWorker } from "./acp-retire";

test("recovery waits for an unresponsive worker to exit, escalating when it ignores termination", async () => {
  const child = spawn(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log("ready"); setInterval(() => {}, 1000)'], { stdio: ["ignore", "pipe", "ignore"] });
  try {
    await once(child.stdout!, "data");
    await retireWorker(child, 20);
    expect(child.signalCode).toBe("SIGKILL");
    await retireWorker(child, 20); // Already exited workers need no second wait.
  } finally { child.kill("SIGKILL"); }
});

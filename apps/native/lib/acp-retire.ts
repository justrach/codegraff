import type { ChildProcess } from "node:child_process";

/** A replacement must not load a session while its old writer is still alive. */
export function retireWorker(child: ChildProcess, graceMs = 1000, request: "signal" | "eof" = "signal"): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve, reject) => {
    let timer = setTimeout(() => {
      if (request === "eof") {
        child.kill("SIGTERM");
        timer = setTimeout(() => child.kill("SIGKILL"), 1000);
      } else child.kill("SIGKILL");
    }, graceMs);
    const cleanup = () => { clearTimeout(timer); child.off("exit", exited); child.off("error", failed); };
    const exited = () => { cleanup(); resolve(); };
    const failed = (error: Error) => { cleanup(); reject(error); };
    child.once("exit", exited);
    child.once("error", failed);
    if (request === "eof") {
      try { child.stdin?.end(); } catch { child.kill("SIGTERM"); }
    } else child.kill("SIGTERM");
  });
}

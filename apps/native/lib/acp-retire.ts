import type { ChildProcess } from "node:child_process";

/** A replacement must not load a session while its old writer is still alive. */
export function retireWorker(child: ChildProcess, graceMs = 1000): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => child.kill("SIGKILL"), graceMs);
    const cleanup = () => { clearTimeout(timer); child.off("exit", exited); child.off("error", failed); };
    const exited = () => { cleanup(); resolve(); };
    const failed = (error: Error) => { cleanup(); reject(error); };
    child.once("exit", exited);
    child.once("error", failed);
    child.kill("SIGTERM");
  });
}

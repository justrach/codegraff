import { spawn } from "node:child_process";

/** Accept the harness result record only after its process completes successfully. */
export function generatedTitle(output: string): string | null {
  const results: unknown[] = [];
  for (const line of output.split("\n")) {
    try {
      const record = JSON.parse(line);
      if (record?.type === "title_result") results.push(record.title);
    } catch { /* Diagnostics are not title results. */ }
  }
  if (results.length !== 1 || typeof results[0] !== "string") return null;
  const title = results[0].trim();
  return title && !/[\r\n\x00-\x1f]/.test(title) ? title.slice(0, 60) : null;
}

export function generateTitle(binary: string, prompt: string, cwd: string, timeoutMs = 20_000): Promise<string | null> {
  return new Promise(resolve => {
    const child = spawn(binary, ["title", "--json", prompt], { cwd, stdio: ["ignore", "pipe", "ignore"] });
    let output = "", done = false;
    const finish = (title: string | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(title);
    };
    const timer = setTimeout(() => { child.kill("SIGKILL"); finish(null); }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      output += chunk;
      if (output.length > 64 * 1024) { child.kill("SIGKILL"); finish(null); }
    });
    child.on("error", () => finish(null));
    child.on("close", (code, signal) => finish(code === 0 && signal === null ? generatedTitle(output) : null));
  });
}

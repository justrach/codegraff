import { existsSync } from "node:fs";
import path from "node:path";

export type CreateResult = {
  name: string;
  path: string;
  branch: string;
  copied: number;
};

/** Same binary the ACP route uses. */
export function graffBin(fromCwd = process.cwd()): string {
  const built = path.resolve(fromCwd, "../../zig-out/bin/graff");
  return process.env.GRAFF_BIN || (existsSync(built) ? built : "graff");
}

export function slugFromCheckout(checkout: string): string | null {
  const parts = checkout.replace(/\\/g, "/").split("/");
  const i = parts.lastIndexOf("worktrees");
  if (i >= 0 && parts[i - 1] === ".graff" && parts[i + 1]) return parts[i + 1];
  return null;
}

export function sanitizeSlug(raw: string): string | null {
  const t = raw.trim();
  if (!t || t.length > 64) return null;
  if (!/^[A-Za-z0-9._-]+$/.test(t)) return null;
  if (t === "." || t === "..") return null;
  return t;
}

export function parseCreate(stdout: string): CreateResult | null {
  const name = stdout.match(/^✓ workspace (\S+)/m)?.[1];
  const dest = stdout.match(/^ {2}path (.+)$/m)?.[1]?.trim();
  const branch = stdout.match(/^ {2}branch (\S+)/m)?.[1];
  if (!name || !dest || !branch) return null;
  const copied = Number(stdout.match(/^ {2}copied (\d+)/m)?.[1] ?? "0");
  return { name, path: dest, branch, copied };
}

export function runCommand(name: string): string {
  return `graff worktree run ${name}`;
}

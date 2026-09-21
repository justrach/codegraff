import path from "node:path";

export function hostOpenCommand(action: string, target: string, platform = process.platform): { bin: string; args: string[] } | null {
  if (action !== "open" && action !== "reveal") return null;
  if (platform === "darwin") return { bin: "open", args: action === "reveal" ? ["-R", target] : [target] };
  if (platform === "linux") return { bin: "xdg-open", args: [action === "reveal" ? path.dirname(target) : target] };
  return null;
}

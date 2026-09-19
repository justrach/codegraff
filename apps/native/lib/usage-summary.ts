export type UsageMetric = { label: string; value: string; note?: string };
export type UsageWindow = { label: string; remaining: number; used: number; reset?: string };
export type UsagePlan = { name: string; plan?: string; windows: UsageWindow[]; notes: string[] };
export type UsageSummary = { metrics: UsageMetric[]; plans: UsagePlan[]; notes: string[] };

const number = (value: string) => Number(value).toLocaleString("en-US");

/** Only used for /usage and /cost replies; unknown lines remain visible. */
export function parseUsageSummary(text: string): UsageSummary | null {
  const lines = text.trim().split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  if (lines[0] !== "session usage" && lines[0] !== "no API calls yet this session") return null;
  const result: UsageSummary = { metrics: [], plans: [], notes: [] };
  let plan: UsagePlan | undefined;
  if (lines[0].startsWith("no API")) result.notes.push("No API calls yet this session.");
  for (const line of lines.slice(1)) {
    if (line === "codex plan" || line === "xai / grok") {
      plan = { name: line === "codex plan" ? "Codex" : "xAI / Grok", windows: [], notes: [] };
      result.plans.push(plan);
      continue;
    }
    if (plan) {
      const tier = /^plan:\s+(.+)$/.exec(line);
      const window = /^(.+?):\s+(\d+)% remaining \((\d+)% used\)(?:, resets in (.+))?$/.exec(line);
      if (tier) plan.plan = tier[1];
      else if (window) plan.windows.push({ label: window[1], remaining: Number(window[2]), used: Number(window[3]), reset: window[4] });
      else plan.notes.push(line);
      continue;
    }
    const calls = /^api calls:\s+(\d+)(.*)$/.exec(line);
    const tokens = /^tokens:\s+(\d+) in \((\d+) cached\) \+ (\d+) out$/.exec(line);
    const cost = /^cost:\s+(\$[\d.]+)(?:\s+\((.*)\))?$/.exec(line);
    if (calls) result.metrics.push({ label: "API calls", value: number(calls[1]), note: calls[2].replace(/[()]/g, "").trim() });
    else if (tokens) result.metrics.push(
      { label: "Input tokens", value: number(tokens[1]), note: `${number(tokens[2])} cached` },
      { label: "Output tokens", value: number(tokens[3]) },
    );
    else if (cost) result.metrics.push({ label: "API cost", value: cost[1], note: cost[2] });
    else result.notes.push(line);
  }
  return result;
}

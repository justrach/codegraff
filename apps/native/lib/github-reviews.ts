export type ReviewPr = {
  number: number;
  title: string;
  author: string;
  url: string;
  isDraft: boolean;
  reviewDecision: string | null;
  headRefName: string;
  checks: string;
};

export function summarizeChecks(rollup: unknown): string {
  if (!Array.isArray(rollup) || rollup.length === 0) return "no checks";
  const states = rollup.map((item) => {
    if (!item || typeof item !== "object") return "";
    const rec = item as { state?: string; conclusion?: string; status?: string };
    return (rec.conclusion || rec.state || rec.status || "").toUpperCase();
  });
  if (states.some((s) => s === "FAILURE" || s === "FAILED" || s === "ERROR")) return "failing";
  if (states.some((s) => s === "PENDING" || s === "IN_PROGRESS" || s === "QUEUED")) return "pending";
  if (states.every((s) => s === "SUCCESS" || s === "SKIPPED" || s === "NEUTRAL")) return "passing";
  return "mixed";
}

export function parsePrList(raw: unknown): ReviewPr[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const rec = item as {
      number?: unknown; title?: unknown; url?: unknown; isDraft?: unknown;
      reviewDecision?: unknown; headRefName?: unknown; author?: { login?: unknown };
      statusCheckRollup?: unknown;
    };
    if (typeof rec.number !== "number" || typeof rec.title !== "string") return [];
    return [{
      number: rec.number,
      title: rec.title,
      author: typeof rec.author?.login === "string" ? rec.author.login : "unknown",
      url: typeof rec.url === "string" ? rec.url : "",
      isDraft: rec.isDraft === true,
      reviewDecision: typeof rec.reviewDecision === "string" ? rec.reviewDecision : null,
      headRefName: typeof rec.headRefName === "string" ? rec.headRefName : "",
      checks: summarizeChecks(rec.statusCheckRollup),
    }];
  });
}

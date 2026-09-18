"use client";
import { useEffect, useState } from "react";
import ResizableReviewPane from "./ResizableReviewPane";
import type { ReviewPr } from "@/lib/github-reviews";

export default function ReviewsPane({ root, onClose }: { root?: string; onClose(): void }) {
  const [prs, setPrs] = useState<ReviewPr[]>([]);
  const [needAuth, setNeedAuth] = useState(false);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<number | null>(null);
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setError("");
    const params = new URLSearchParams();
    if (root) params.set("root", root);
    const response = await fetch(`/api/reviews?${params}`, { cache: "no-store" });
    const body = await response.json() as { ok?: boolean; needAuth?: boolean; prs?: ReviewPr[]; error?: string };
    if (!response.ok) throw new Error(body.error ?? "Could not load reviews.");
    setNeedAuth(body.needAuth === true);
    setPrs(body.prs ?? []);
  };

  useEffect(() => {
    let alive = true;
    void load().catch((err: unknown) => { if (alive) setError(err instanceof Error ? err.message : "Could not load reviews."); });
    return () => { alive = false; };
  }, [root]);

  const review = async (event: "APPROVE" | "COMMENT" | "REQUEST_CHANGES") => {
    if (selected == null) return;
    setBusy(true); setError("");
    try {
      const response = await fetch("/api/reviews", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ root, number: selected, event, body: comment }),
      });
      const body = await response.json() as { error?: string };
      if (!response.ok) throw new Error(body.error ?? "Could not submit review.");
      setComment("");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not submit review.");
    } finally { setBusy(false); }
  };

  const current = prs.find((pr) => pr.number === selected);
  return <ResizableReviewPane label="reviews">
    <section aria-label="Reviews" className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page">
      <header className="flex h-10 shrink-0 items-center gap-2 border-b border-line px-3">
        <strong className="min-w-0 flex-1 truncate text-[13px] font-medium">Reviews</strong>
        <button type="button" aria-label="Close reviews" onClick={onClose} className="flex size-7 items-center justify-center rounded-md text-ink-3 hover:bg-hover">×</button>
      </header>
      {needAuth ? (
        <div className="flex flex-1 flex-col gap-2 p-4 text-[13px] text-ink-2">
          <p>Sign in with GitHub to see this project's review inbox.</p>
          <p className="text-[12px] text-ink-3">In a terminal: <span className="font-mono text-ink">gh auth login</span></p>
        </div>
      ) : (
        <div className="flex min-h-0 flex-1">
          <ul className="w-44 shrink-0 overflow-y-auto border-r border-line p-2">
            {prs.length === 0 && <li className="px-2 py-3 text-[12px] text-ink-3">No open pull requests.</li>}
            {prs.map((pr) => (
              <li key={pr.number}>
                <button type="button" onClick={() => setSelected(pr.number)} className={`mb-1 w-full rounded-[8px] px-2 py-1.5 text-left ${selected === pr.number ? "bg-hover-2 text-ink" : "text-ink-2 hover:bg-hover"}`}>
                  <span className="block truncate text-[12.5px] font-medium">#{pr.number} {pr.title}</span>
                  <span className="block truncate text-[11px] text-ink-3">{pr.author} · {pr.checks}{pr.isDraft ? " · draft" : ""}</span>
                </button>
              </li>
            ))}
          </ul>
          <div className="min-w-0 flex-1 overflow-y-auto p-3 text-[13px]">
            {!current ? <p className="text-ink-3">Select a pull request.</p> : <>
              <a href={current.url} className="font-medium text-ink hover:underline" target="_blank" rel="noreferrer">#{current.number} {current.title}</a>
              <p className="mt-1 text-[12px] text-ink-3">{current.headRefName} · {current.reviewDecision ?? "awaiting review"}</p>
              <textarea value={comment} onChange={(event) => setComment(event.target.value)} placeholder="Review comment" className="mt-3 h-24 w-full rounded-[8px] bg-inset p-2 font-sans text-[12.5px] shadow-hairline" />
              <div className="mt-2 flex flex-wrap gap-1">
                <button type="button" disabled={busy} onClick={() => void review("COMMENT")} className="h-7 rounded-full px-2.5 text-[12px] text-ink-2 hover:bg-hover">Comment</button>
                <button type="button" disabled={busy} onClick={() => void review("APPROVE")} className="h-7 rounded-full px-2.5 text-[12px] text-ink-2 hover:bg-hover">Approve</button>
                <button type="button" disabled={busy} onClick={() => void review("REQUEST_CHANGES")} className="h-7 rounded-full px-2.5 text-[12px] text-ink-2 hover:bg-hover">Request changes</button>
              </div>
            </>}
          </div>
        </div>
      )}
      {error && <p role="alert" className="border-t border-line px-3 py-2 text-[12px] text-red">{error}</p>}
    </section>
  </ResizableReviewPane>;
}

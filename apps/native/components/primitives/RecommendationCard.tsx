"use client";

import { useState } from "react";
import { Button, type ButtonVariant } from "@/components/atoms/Button";

/* ─────────────────────────────────────────────────────────
 * RECOMMENDATION CARD
 * The card holds its shape. Pressing "Alternatives" opens a
 * new drawer listing the other options; picking one promotes
 * it to the recommendation. The primary action confirms.
 * ───────────────────────────────────────────────────────── */

type Option = {
  key: string;
  body: React.ReactNode;
  short: string;
  signal: number;
  tone: string;
  label: string;
  cta: string;
  ctaVariant: ButtonVariant;
};

/* a supplier as a little logo chip — circular mark + name, no external arrow */
function VendorChip({ name, color = "#e08a3c" }: { name: string; color?: string }) {
  return (
    <span className="mx-0.5 inline-flex items-center gap-1 rounded-full bg-field py-px pl-[3px] pr-1.5 align-middle shadow-hairline">
      <span
        className="flex size-4 shrink-0 items-center justify-center rounded-full text-[9px] font-semibold leading-none text-white"
        style={{ background: color }}
      >
        {name.charAt(0)}
      </span>
      <span className="text-[12px] font-medium text-ink">{name}</span>
    </span>
  );
}

/* a plain value as a soft rounded badge — not a mono token */
function Pill({ children, tone = "neutral" }: { children: React.ReactNode; tone?: "neutral" | "green" }) {
  return (
    <span
      className={`mx-0.5 inline-flex items-center rounded-full px-1.5 py-0 align-middle text-[12px] font-medium ${
        tone === "green" ? "bg-green-tint text-green" : "bg-field text-ink-2"
      }`}
      style={{
        boxShadow: tone === "green"
          ? "0 0 0 1px color-mix(in oklch, var(--green) 28%, transparent)"
          : "var(--shadow-hairline)",
      }}
    >
      {children}
    </span>
  );
}

const OPTIONS: Option[] = [
  {
    key: "high",
    body: (
      <>
        Reorder waffle cones from{" "}
        <VendorChip name="Cone King" />{" "}
        with lead time <Pill tone="green">7 days</Pill>
      </>
    ),
    short: "Reorder from Cone King · 7-day lead",
    signal: 3,
    tone: "var(--green)",
    label: "High confidence",
    cta: "Accept",
    ctaVariant: "accent",
  },
  {
    key: "review",
    body: (
      <>
        Switch vanilla to <Pill>Vanilla Madagascar</Pill> for peak season.
      </>
    ),
    short: "Switch to Vanilla Madagascar",
    signal: 2,
    tone: "var(--orange)",
    label: "Needs review",
    cta: "Configure",
    ctaVariant: "primary",
  },
  {
    key: "none",
    body: (
      <>
        Fall back to a <span className="font-medium text-ink">full restock</span> across every SKU.
      </>
    ),
    short: "Full restock across every SKU",
    signal: 0,
    tone: "var(--ink-3)",
    label: "No signal",
    cta: "Accept full restock",
    ctaVariant: "primary",
  },
];

function Meter({ signal, tone }: { signal: number; tone: string }) {
  return (
    <span className="flex items-end gap-0.5">
      {[0, 1, 2].map((bar) => (
        <span
          key={bar}
          className="w-1 rounded-full transition-colors duration-300"
          style={{ height: 10, background: bar < signal ? tone : "var(--line-strong)" }}
        />
      ))}
    </span>
  );
}

export default function RecommendationCard() {
  const [selected, setSelected] = useState(0);
  const [open, setOpen] = useState(false);
  const [accepted, setAccepted] = useState(false);

  const active = OPTIONS[selected];
  const others = OPTIONS.map((o, i) => ({ o, i })).filter(({ i }) => i !== selected);

  return (
    <div className="w-full max-w-95 overflow-hidden rounded-card bg-surface shadow-card">
      <div className="primitive-card-pad">
        <span className="text-[14px] font-medium text-ink">
          Want me to place this restock order?
        </span>
        <p
          key={active.key}
          className="mt-1.5 min-h-12 text-[13px] leading-relaxed text-ink-2"
          style={{ animation: "fade-in 180ms ease-out both" }}
        >
          {active.body}
        </p>
      </div>

      {/* alternatives drawer — a distinctly new section of the card */}
      <div
        className="grid transition-[grid-template-rows,opacity] duration-300"
        style={{
          gridTemplateRows: open ? "1fr" : "0fr",
          opacity: open ? 1 : 0,
          transitionTimingFunction: "cubic-bezier(0.16, 1, 0.3, 1)",
        }}
      >
        <div className="overflow-hidden">
          <div className="border-t border-line bg-surface px-2 py-2">
            <p className="px-1.5 pb-1 text-[11px] font-medium text-ink-3">
              Other options
            </p>
            {others.map(({ o, i }) => (
              <button
                key={o.key}
                type="button"
                onClick={() => {
                  setSelected(i);
                  setAccepted(false);
                }}
                className="flex w-full items-center gap-2.5 rounded-control px-1.5 py-1.5
                  text-left transition-colors duration-100 hover:bg-hover"
              >
                <Meter signal={o.signal} tone={o.tone} />
                <span className="min-w-0 flex-1 truncate text-[12.5px] text-ink">{o.short}</span>
                <span className="shrink-0 text-[11px] text-ink-3">{o.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="primitive-card-footer flex items-center justify-between gap-3 bg-surface">
        <span className="flex items-center gap-2">
          <Meter signal={active.signal} tone={active.tone} />
          <span className="text-[12.5px] font-medium text-ink-2">{active.label}</span>
        </span>

        <span className="-mr-0.5 flex items-center gap-2">
          <Button
            variant="secondary"
            size="sm"
            aria-expanded={open}
            onClick={() => setOpen((current) => !current)}
            className="px-2.5 text-[12.5px]"
          >
            Alternatives
          </Button>
          <Button
            variant={accepted ? "success" : active.ctaVariant}
            size="sm"
            onClick={() => setAccepted(true)}
            className="text-[12.5px]"
          >
            {accepted ? "Accepted" : active.cta}
          </Button>
        </span>
      </div>
    </div>
  );
}

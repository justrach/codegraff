type Tone = "green" | "orange" | "red" | "accent" | "neutral";

const tones: Record<Tone, { bg: string; fg: string; dot: string }> = {
  green: { bg: "bg-green-tint", fg: "text-green", dot: "bg-green" },
  orange: { bg: "bg-orange-tint", fg: "text-orange", dot: "bg-orange" },
  red: { bg: "bg-red-tint", fg: "text-red", dot: "bg-red" },
  accent: { bg: "bg-accent-tint", fg: "text-accent-ink", dot: "bg-accent" },
  neutral: { bg: "bg-inset", fg: "text-ink-2", dot: "bg-ink-3" },
};

export function StatusPill({
  tone = "neutral",
  children,
  dot = true,
  className = "",
}: {
  tone?: Tone;
  children: React.ReactNode;
  dot?: boolean;
  className?: string;
}) {
  const t = tones[tone];
  return (
    <span
      className={`inline-flex h-6 items-center gap-1.5 rounded-full px-2.5
        text-[13px] font-medium leading-none ${t.bg} ${t.fg} ${className}`}
    >
      {dot && <span className={`size-1.5 rounded-full ${t.dot}`} />}
      {children}
    </span>
  );
}

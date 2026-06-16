import { PaperclipIcon } from "lucide-react";

export function DropOverlay({
  label = "Drop files to attach",
}: {
  label?: string;
}) {
  return (
    <div className="pointer-events-none absolute inset-0 z-30 flex items-center justify-center rounded-2xl border-2 border-dashed border-[color:var(--accent)] bg-[color:color-mix(in_oklab,var(--accent)_12%,transparent)]">
      <div className="flex items-center gap-2 rounded-full bg-background/85 px-3 py-1.5 text-xs font-medium text-foreground shadow-sm">
        <PaperclipIcon className="size-3.5 text-[color:var(--accent)]" />
        {label}
      </div>
    </div>
  );
}

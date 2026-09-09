"use client";

import { useEffect, useId, useState } from "react";

let mermaidModule: Promise<typeof import("mermaid").default> | null = null;
function loadMermaid() {
  mermaidModule ??= import("mermaid").then((mod) => mod.default);
  return mermaidModule;
}

function useDark() {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    const sync = () => setDark(document.documentElement.classList.contains("dark"));
    sync();
    const obs = new MutationObserver(sync);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => obs.disconnect();
  }, []);
  return dark;
}

/** Renders a closed mermaid fence as SVG. Invalid source falls back to the text. */
export default function MermaidDiagram({ code }: { code: string }) {
  const dark = useDark();
  const reactId = useId().replace(/:/g, "");
  const [svg, setSvg] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [zoomed, setZoomed] = useState(false);

  useEffect(() => {
    if (!zoomed) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setZoomed(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [zoomed]);

  useEffect(() => {
    let cancelled = false;
    setSvg(null);
    setFailed(false);
    void (async () => {
      try {
        const mermaid = await loadMermaid();
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme: dark ? "dark" : "default",
          fontFamily: "inherit",
        });
        const { svg: rendered } = await mermaid.render(`graff-mermaid-${reactId}-${dark ? "d" : "l"}`, code);
        if (!cancelled) setSvg(rendered);
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [code, dark, reactId]);

  if (failed) {
    return (
      <pre data-streamdown="mermaid-block" data-mermaid="failed" className="overflow-x-auto rounded-md border border-line bg-surface p-3 text-[12px] text-ink-2">
        <code>{code.replace(/\n+$/, "")}</code>
      </pre>
    );
  }
  if (!svg) {
    return (
      <div data-streamdown="mermaid-block" role="status" className="rounded-md border border-line bg-surface px-3 py-2 text-[12px] text-ink-3">
        Rendering diagram…
      </div>
    );
  }

  const figure = (
    <div
      className="max-w-full overflow-x-auto p-3 [&_svg]:mx-auto [&_svg]:h-auto [&_svg]:max-w-full"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );

  return (
    <>
      <div
        data-streamdown="mermaid-block"
        role="button"
        tabIndex={0}
        title="Click to enlarge"
        onClick={() => setZoomed(true)}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            setZoomed(true);
          }
        }}
        className="cursor-zoom-in rounded-xl border border-line bg-surface"
      >
        {figure}
      </div>
      {zoomed && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-page/80 p-6"
          onClick={() => setZoomed(false)}
        >
          <button type="button" aria-label="Close diagram" className="absolute right-4 top-4 rounded-lg px-2 py-1 text-sm text-ink-2 hover:bg-hover">
            Esc
          </button>
          <div className="max-h-full max-w-full overflow-auto rounded-xl border border-line bg-surface p-4" onClick={(event) => event.stopPropagation()}>
            {figure}
          </div>
        </div>
      )}
    </>
  );
}

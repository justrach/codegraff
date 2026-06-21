import { useEffect, useState } from "react";

import { useThemeStore } from "@/app/themeStore";
import { CodeBlock } from "./CodeBlock";

// Lazy-load mermaid once (it is a large dependency) and reuse the module so it
// stays out of the initial bundle and only loads when a diagram is shown.
let mermaidModule: Promise<typeof import("mermaid").default> | null = null;
function loadMermaid() {
  if (mermaidModule == null) {
    mermaidModule = import("mermaid").then((module) => module.default);
  }
  return mermaidModule;
}

let renderSeq = 0;

export function MermaidDiagram({ code }: { code: string }) {
  const mode = useThemeStore((state) => state.mode);
  const [svg, setSvg] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setFailed(false);

    void (async () => {
      try {
        const mermaid = await loadMermaid();
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme: mode === "dark" ? "dark" : "default",
          fontFamily: "inherit",
        });
        const id = `cg-mermaid-${(renderSeq += 1)}`;
        const { svg: rendered } = await mermaid.render(id, code);
        if (!cancelled) {
          setSvg(rendered);
        }
      } catch {
        if (!cancelled) {
          setFailed(true);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [code, mode]);

  // Won't parse -> fall back to the raw fenced source so nothing is lost.
  if (failed) {
    return <CodeBlock value={code} lang="mermaid" />;
  }

  if (svg == null) {
    return (
      <div className="rounded-md border border-border/70 bg-card/40 px-3 py-2 text-xs text-muted-foreground">
        Rendering diagram…
      </div>
    );
  }

  return (
    <div
      className="cg-mermaid max-w-full overflow-x-auto rounded-md border border-border/70 bg-card/40 p-3 [&_svg]:mx-auto [&_svg]:h-auto [&_svg]:max-w-full"
      // mermaid renders with securityLevel "strict", which sanitizes the SVG.
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}

import { useEffect, useRef, useState } from "react";
import { Maximize2, X } from "lucide-react";

import { useThemeStore } from "@/app/themeStore";
import { CodeBlock } from "./CodeBlock";

// Lazy-load mermaid (large dep) once and reuse the module so it stays out of
// the initial bundle and only loads when a diagram is actually rendered.
let mermaidModule: Promise<typeof import("mermaid").default> | null = null;
function loadMermaid() {
  if (mermaidModule == null) {
    mermaidModule = import("mermaid").then((module) => module.default);
  }
  return mermaidModule;
}

let renderSeq = 0;

// Fullscreen overlay that lets a dense diagram be scroll-zoomed and drag-panned.
function MermaidZoom({ svg, onClose }: { svg: string; onClose: () => void }) {
  const [scale, setScale] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const dragOrigin = useRef<{ x: number; y: number } | null>(null);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  function handleWheel(event: React.WheelEvent) {
    event.preventDefault();
    const factor = Math.exp(-event.deltaY * 0.0015);
    setScale((current) => Math.min(12, Math.max(0.4, current * factor)));
  }

  function handlePointerDown(event: React.PointerEvent) {
    dragOrigin.current = {
      x: event.clientX - offset.x,
      y: event.clientY - offset.y,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function handlePointerMove(event: React.PointerEvent) {
    if (dragOrigin.current == null) {
      return;
    }
    setOffset({
      x: event.clientX - dragOrigin.current.x,
      y: event.clientY - dragOrigin.current.y,
    });
  }

  function handlePointerUp() {
    dragOrigin.current = null;
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-background/80 backdrop-blur-sm"
      onClick={onClose}
    >
      <div className="pointer-events-none absolute left-1/2 top-4 -translate-x-1/2 rounded-full border border-border/60 bg-card/80 px-3 py-1 text-xs text-muted-foreground">
        scroll to zoom · drag to pan · esc to close
      </div>
      <button
        type="button"
        onClick={onClose}
        aria-label="Close diagram"
        className="absolute right-4 top-4 inline-flex size-9 items-center justify-center rounded-full border border-border bg-card/80 text-foreground transition hover:bg-card"
      >
        <X className="size-4" />
      </button>
      <div
        className="h-full w-full cursor-grab touch-none select-none active:cursor-grabbing"
        onClick={(event) => event.stopPropagation()}
        onWheel={handleWheel}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerLeave={handlePointerUp}
      >
        <div
          className="flex h-full w-full items-center justify-center [&_svg]:h-auto [&_svg]:max-w-none"
          style={{
            transform: `translate(${offset.x}px, ${offset.y}px) scale(${scale})`,
            transformOrigin: "center",
          }}
          dangerouslySetInnerHTML={{ __html: svg }}
        />
      </div>
    </div>
  );
}

export function MermaidDiagram({ code }: { code: string }) {
  const mode = useThemeStore((state) => state.mode);
  const renderKey = `${mode}\0${code}`;
  const [renderResult, setRenderResult] = useState<{
    key: string;
    status: "ready" | "failed";
    svg: string | null;
  } | null>(null);
  const [zoomed, setZoomed] = useState(false);
  const currentResult =
    renderResult?.key === renderKey ? renderResult : null;

  useEffect(() => {
    let cancelled = false;

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
          setRenderResult({
            key: renderKey,
            status: "ready",
            svg: rendered,
          });
        }
      } catch {
        if (!cancelled) {
          setRenderResult({
            key: renderKey,
            status: "failed",
            svg: null,
          });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [code, mode, renderKey]);

  if (currentResult?.status === "failed") {
    return <CodeBlock value={code} lang="mermaid" />;
  }

  if (currentResult?.svg == null) {
    return (
      <div className="rounded-md border border-border/70 bg-card/40 px-3 py-2 text-xs text-muted-foreground">
        Rendering diagram…
      </div>
    );
  }

  return (
    <>
      <div
        role="button"
        tabIndex={0}
        title="Click to zoom"
        onClick={() => setZoomed(true)}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            setZoomed(true);
          }
        }}
        className="cg-mermaid group relative cursor-zoom-in rounded-md border border-border/70 bg-card/40"
      >
        <div
          className="max-w-full overflow-x-auto p-3 [&_svg]:mx-auto [&_svg]:h-auto [&_svg]:max-w-full"
          dangerouslySetInnerHTML={{ __html: currentResult.svg }}
        />
        <div className="pointer-events-none absolute right-2 top-2 rounded-md bg-card/70 p-1 text-muted-foreground opacity-0 transition group-hover:opacity-100">
          <Maximize2 className="size-3.5" />
        </div>
      </div>
      {zoomed ? (
        <MermaidZoom
          svg={currentResult.svg}
          onClose={() => setZoomed(false)}
        />
      ) : null}
    </>
  );
}

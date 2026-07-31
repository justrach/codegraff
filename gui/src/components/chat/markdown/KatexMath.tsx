import { useMemo } from "react";
import katex from "katex";

// KaTeX renders math the local Markdown parser captured as `\[...\]`/`$$...$$`
// (display) or `\(...\)`/`$...$` (inline). renderToString is pure (no DOM), so
// this stays server-renderable and unit-testable. katex.min.css is bundled
// globally via src/styles/index.css (@import), mirroring how shadcn/tailwind.css
// is pulled in, so this component carries no CSS import the (non-Vite) test
// runner would fail to resolve.
//
// throwOnError:false makes an incomplete (still-streaming) or malformed formula
// render as a visible KaTeX error instead of throwing; trust:false keeps
// \href/\includegraphics and raw-HTML commands from injecting anything unsafe.
interface KatexMathProps {
  latex: string;
  display?: boolean;
}

export function KatexMath({ latex, display = false }: KatexMathProps) {
  const html = useMemo(() => {
    try {
      return katex.renderToString(latex, {
        displayMode: display,
        throwOnError: false,
        output: "htmlAndMathml",
        trust: false,
        strict: "ignore",
      });
    } catch {
      return null;
    }
  }, [latex, display]);

  if (html == null) {
    // renderToString unexpectedly threw: show the raw source rather than nothing.
    return display ? (
      <pre className="overflow-x-auto">
        <code>{latex}</code>
      </pre>
    ) : (
      <code>{latex}</code>
    );
  }

  if (display) {
    return (
      <div className="my-2 overflow-x-auto" dangerouslySetInnerHTML={{ __html: html }} />
    );
  }

  return <span dangerouslySetInnerHTML={{ __html: html }} />;
}

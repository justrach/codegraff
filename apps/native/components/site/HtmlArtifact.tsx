"use client";
import { useEffect, useMemo, useRef, useState } from 'react';
import { previewDocument } from '@/lib/html-preview';

type Artifact = { title: string; html: string };
export default function HtmlArtifact({ id }: { id: string }) {
  const root = useRef<HTMLElement>(null);
  const [nearby, setNearby] = useState(false), [hidden, setHidden] = useState(false);
  const [source, setSource] = useState(false), [data, setData] = useState<Artifact | null>(null);
  const [error, setError] = useState(''), [copied, setCopied] = useState(false);
  useEffect(() => {
    const observer = new IntersectionObserver(entries => setNearby(entries.some(entry => entry.isIntersecting)), { rootMargin: '80px' });
    if (root.current) observer.observe(root.current);
    return () => observer.disconnect();
  }, []);
  const active = nearby && !hidden;
  useEffect(() => {
    setData(null); setError(''); setCopied(false);
    if (!active) return;
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 10000);
    let cancelled = false;
    void fetch(`/api/html-artifacts?id=${id}`, { signal: controller.signal, credentials: 'same-origin' })
      .then(async response => { if (!response.ok) throw Error('Saved preview unavailable'); return response.json(); })
      .then(value => { if (!cancelled) setData(value); })
      .catch(() => { if (!cancelled) setError('This saved preview could not be loaded.'); })
      .finally(() => clearTimeout(deadline));
    return () => { cancelled = true; clearTimeout(deadline); controller.abort(); };
  }, [id, active]);
  const rendered = useMemo(() => {
    if (!data) return { document: '', error: '' };
    try { return { document: previewDocument(data.html), error: '' }; }
    catch { return { document: '', error: 'This HTML is too complex to preview. You can still inspect and copy its source.' }; }
  }, [data]);
  const button = (selected = false) => `rounded-md px-2 py-1 text-xs ${selected ? 'bg-hover text-ink' : 'text-ink-3 hover:text-ink'}`;
  return <section ref={root} data-html-artifact={id} className="my-3 overflow-hidden rounded-xl border border-line bg-surface" aria-label="Saved HTML explanation">
    <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-3 py-2">
      <div className="min-w-0"><div className="truncate text-sm font-medium">{data?.title || 'HTML explanation'}</div><div className="text-[10px] text-ink-3">Static HTML · scripts and external resources are disabled</div></div>
      <div className="flex gap-1"><button data-html-preview aria-pressed={!source} className={button(!source)} onClick={()=>setSource(false)}>Preview</button><button data-html-source aria-pressed={source} className={button(source)} onClick={()=>setSource(true)}>HTML</button><button data-html-copy disabled={!data} className={button()} onClick={async()=>{try{await navigator.clipboard.writeText(data!.html);setCopied(true);}catch{setError('Copy failed. You can select the source from HTML.');}}}>{copied?'Copied':'Copy'}</button><button data-html-hide aria-expanded={!hidden} className={button()} onClick={()=>setHidden(!hidden)}>{hidden?'Show':'Hide'}</button></div>
    </header>
    {!hidden && <div className="min-h-[440px]">
      {error && <p role="status" className="p-4 text-sm text-ink-3">{error}</p>}
      {!error && !data && <p className="p-4 text-sm text-ink-3">{nearby?'Loading saved preview…':'Preview paused while offscreen.'}</p>}
      {data && (source ? <pre data-html-source-body className="h-[440px] overflow-auto p-4 text-xs"><code>{data.html}</code></pre>
        : rendered.error ? <p role="status" className="p-4 text-sm text-ink-3">{rendered.error}</p>
        : active && <iframe data-html-frame title={data.title} srcDoc={rendered.document} sandbox="" referrerPolicy="no-referrer" className="block h-[440px] w-full border-0 bg-white" />)}
    </div>}
  </section>;
}

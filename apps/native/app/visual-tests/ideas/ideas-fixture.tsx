"use client";
import { useEffect, useState } from 'react';
import { previewDocument } from './preview-document';
import { sampleHtml } from './sample-html';

export default function IdeasFixture() {
  const [page, setPage] = useState('chat');
  const [view, setView] = useState('preview');
  const [visible, setVisible] = useState(true);
  const [html, setHtml] = useState(sampleHtml);
  const [srcDoc, setSrcDoc] = useState('');
  const [diagnostics, setDiagnostics] = useState(false);
  const [copied, setCopied] = useState(false);
  useEffect(() => { setSrcDoc(previewDocument(html)); }, [html]);
  useEffect(() => {
    const receive = (event: Event) => setHtml((event as CustomEvent).detail);
    window.addEventListener('fixture-html', receive);
    return () => window.removeEventListener('fixture-html', receive);
  }, []);
  const tab = (active: boolean) => `rounded-lg px-3 py-1.5 text-xs ${active ? 'bg-white text-[#274b3d] shadow-sm' : 'text-[#738176]'}`;
  return <main data-ideas-ready={!!srcDoc} className="min-h-screen bg-[#fafbf8] text-[#263a31]" style={{fontFamily:'Arial, sans-serif'}}>
    <header className="flex h-16 items-center justify-between border-b border-[#e0e6dc] px-8">
      <div className="flex items-center gap-3"><span className="text-xl text-[#4e755d]">◈</span><strong className="text-sm">Codegraff</strong><span className="text-xs text-[#829087]">/ Ideas</span></div>
      <div className="flex gap-1 rounded-xl bg-[#edf1e9] p-1"><button data-ideas-chat className={tab(page==='chat')} onClick={()=>setPage('chat')}>Inline preview</button><button data-ideas-diagnostics className={tab(page==='diagnostics')} onClick={()=>setPage('diagnostics')}>Diagnostics settings</button></div>
      <span className="text-[11px] text-[#7d8b80]">Prototype · nothing is sent</span>
    </header>
    {page === 'chat' ? <div className="mx-auto max-w-[820px] px-8 pb-8 pt-9">
      <div className="mb-8 ml-auto w-fit rounded-2xl bg-[#e9efe5] px-5 py-3 text-sm">Can you explain how the app uses memory, visually?</div>
      <div className="mb-4 flex items-center gap-2 text-xs text-[#829087]"><span>✧</span> Worked for 8s</div>
      <p className="mb-5 text-[15px] leading-6">Here’s a view of the three parts. Open the question below to see what happens when you close a tab.</p>
      <section className="overflow-hidden rounded-2xl border border-[#d9e2d5] bg-white shadow-[0_5px_22px_#20382206]" aria-label="Inline HTML explanation">
        <div className="flex items-center justify-between border-b border-[#e4e9df] px-4 py-3">
          <div className="flex items-center gap-3"><span className="rounded-md bg-[#edf3e9] px-2 py-1 font-mono text-xs text-[#668061]">&lt;/&gt;</span><div><div className="text-[13px] font-semibold">Understanding app memory</div><div className="mt-0.5 text-[10px] text-[#889183]">HTML explanation · stays in this reply</div></div></div>
          <div className="flex items-center gap-2"><div className="flex rounded-lg bg-[#f0f3ec] p-0.5"><button data-html-preview className={tab(view==='preview')} onClick={()=>setView('preview')}>Preview</button><button data-html-source className={tab(view==='source')} onClick={()=>setView('source')}>HTML</button></div><button data-html-copy className="px-2 text-xs text-[#7e8b7a]" onClick={async()=>{await navigator.clipboard.writeText(html);setCopied(true);}}> {copied ? 'Copied' : 'Copy'}</button><button data-html-hide className="px-2 text-xs text-[#7e8b7a]" aria-expanded={visible} onClick={()=>setVisible(!visible)}>{visible?'Hide':'Show'}</button></div>
        </div>
        {visible && (view==='preview' ? srcDoc && <iframe data-html-frame title="Understanding app memory" sandbox="" referrerPolicy="no-referrer" srcDoc={srcDoc} className="block h-[420px] w-full border-0"/> : <pre data-html-source-body className="h-[420px] overflow-auto bg-[#f4f7f1] p-5 text-[11px] leading-5"><code>{html}</code></pre>)}
      </section>
      <div className="mt-6 flex h-[70px] items-center justify-between rounded-2xl border border-[#dfe6d9] bg-white px-5 text-sm text-[#8e998c]"><span>Ask a follow-up…</span><span className="rounded-xl bg-[#edf2e8] px-3 py-1 text-[#628059]">↑</span></div>
    </div> : <div className="mx-auto max-w-[750px] px-8 py-10">
      <div className="mb-2 text-xs font-semibold uppercase tracking-[0.16em] text-[#7c8f77]">Privacy & diagnostics</div><h1 className="mb-3 text-3xl tracking-tight">Help make Codegraff feel better.</h1><p className="mb-7 max-w-[600px] text-sm leading-6 text-[#7d8878]">Share a small report about speed and reliability. You can inspect the fields below and turn sharing off at any time.</p>
      <section className="rounded-2xl border border-[#dce5d6] bg-white p-6"><div className="flex items-center justify-between"><div><h2 className="text-sm font-semibold">Share anonymous desktop diagnostics</h2><p className="mt-1 text-xs text-[#8a9486]">Optional · off by default</p></div><button data-diagnostics-toggle role="switch" aria-checked={diagnostics} aria-label="Share anonymous desktop diagnostics" onClick={()=>setDiagnostics(!diagnostics)} className={`w-11 rounded-full p-1 ${diagnostics?'bg-[#557853]':'bg-[#dfe5da]'}`}><span className={`block h-4 w-4 rounded-full bg-white ${diagnostics?'translate-x-5':''}`}/></button></div>
      <div className="my-6 border-t border-[#e8ece3]"/><div className="grid grid-cols-2 gap-8"><div><h3 className="mb-3 text-xs font-semibold text-[#57764b]">What is included</h3><ul className="space-y-3 text-xs leading-5 text-[#737e6c]"><li>App version and OS family</li><li>Startup and interaction timing ranges</li><li>Memory / CPU ranges while active</li><li>Crash, disconnect and recovery counts</li></ul></div><div><h3 className="mb-3 text-xs font-semibold text-[#737d6c]">What stays on your device</h3><ul className="space-y-3 text-xs leading-5 text-[#737e6c]"><li>Chats, code and generated HTML</li><li>File paths, page URLs and titles</li><li>Account and persistent device identifiers</li><li>Screenshots, keystrokes and raw errors</li></ul></div></div></section>
      <details className="mt-5 rounded-xl border border-[#e1e7dc] bg-[#f2f5ee] p-4"><summary className="cursor-pointer text-xs font-semibold">Inspect an example report</summary><pre className="mt-4 overflow-auto text-[11px] text-[#687960]">{JSON.stringify({schema:'desktop-diagnostics-v1',release:'example',os:'macos',event:'ui_ready',duration_bucket:'under_2s'},null,2)}</pre></details>
      <p className="mt-5 text-xs leading-5 text-[#8c9785]">This is a settings prototype. Changing the switch sends nothing. Collector-side IP removal and retention rules still need verification before release.</p>
    </div>}
  </main>;
}

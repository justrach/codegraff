'use client';
import { useEffect, useRef, useState } from 'react';
import { agentKey, agentName, workingAgentCount, agentRequest, type AgentSnapshot, type LocalAgent } from '@/lib/agents';
import ResizableReviewPane from './ResizableReviewPane';
import SubagentActivity from './SubagentActivity';
import AgentCard, { AgentStatus } from './AgentCard';

type Draft = { text: string; kind: string; notice: string; failed: boolean; sending: boolean };
const emptyDraft: Draft = { text: '', kind: 'message', notice: '', failed: false, sending: false };

export default function AgentsPane({ root, onClose, request = agentRequest, fullWidth = false, onOccupancy }: { root?: string; onClose(): void; request?: typeof agentRequest; fullWidth?: boolean; onOccupancy?(count: number): void }) {
  const [scope, setScope] = useState('workspace');
  const [showIdle, setShowIdle] = useState(false);
  const [snapshot, setSnapshot] = useState<AgentSnapshot | null>(null);
  const [error, setError] = useState('');
  const [recipient, setRecipient] = useState<LocalAgent | null>(null);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [refresh, setRefresh] = useState(0);
  const [composing, setComposing] = useState(false);
  const content = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const pending = useRef(new Set<string>());
  useEffect(() => { setRecipient(null); setComposing(false); }, [root]);
  useEffect(() => {
    if (!snapshot || !recipient || snapshot.agents.some(agent => agentKey(agent) === agentKey(recipient))) return;
    setRecipient(null); setComposing(false);
  }, [snapshot, recipient]);
  useEffect(() => {
    let disposed = false, timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    setSnapshot(null); setError('');
    const poll = async () => {
      try {
        if (document.visibilityState !== 'hidden') {
          const data = await request(root, { action: 'list', scope }, controller.signal);
          if (!disposed) { setSnapshot(data); setError(''); onOccupancy?.(workingAgentCount(data.agents)); }
        }
      } catch (e) { if (!disposed) setError(e instanceof Error ? e.message : 'Agents unavailable'); }
      finally { if (!disposed) timer = setTimeout(poll, 5000); }
    };
    void poll();
    return () => { disposed = true; controller.abort(); clearTimeout(timer); };
  }, [root, scope, refresh, request]);
  useEffect(() => { if (composing) input.current?.focus(); }, [composing]);
  const connected = snapshot?.agents ?? [];
  const agents = connected.filter(agent => showIdle || agent.status === 'working');
  const selected = connected.find(a => recipient && agentKey(a) === agentKey(recipient));
  const draftKey = JSON.stringify([root ?? '', recipient ? agentKey(recipient) : '']);
  const draft = drafts[draftKey] ?? emptyDraft;
  const updateDraft = (key: string, patch: Partial<Draft>) => setDrafts(current => ({ ...current, [key]: { ...(current[key] ?? emptyDraft), ...patch } }));
  const name = (session: string) => connected.find(a => a.session === session)?.title || session || 'Workspace';
  const choose = (agent: LocalAgent) => { setRecipient(agent); setComposing(false); content.current?.scrollTo({ top: 0 }); };
  const compose = (kind: string) => { updateDraft(draftKey, { kind }); setComposing(true); input.current?.focus(); };
  const submit = async () => {
    if (!selected || !draft.text.trim() || pending.current.has(draftKey)) return;
    const key = draftKey;
    pending.current.add(key);
    updateDraft(key, { sending: true, notice: '', failed: false });
    try {
      await request(root, { action: 'send', target: selected.session, startId: selected.startId, text: draft.text, kind: draft.kind });
      updateDraft(key, { text: '', notice: 'Queued · Graff will read this at its next step.', failed: false });
    } catch (e) { updateDraft(key, { notice: e instanceof Error ? e.message : 'Message could not be queued', failed: true }); }
    finally { pending.current.delete(key); updateDraft(key, { sending: false }); }
  };
  const messages = snapshot?.messages.filter(message => !selected || message.to === selected.session || message.from_session === selected.session) ?? [];
  const pane = <aside aria-label="Agents panel" className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page text-ink">
    <header className="flex items-center gap-3 border-b border-line p-4"><div className="min-w-0 flex-1"><strong>Agents <span className="font-normal text-ink-3">{snapshot ? agents.length : ''}</span></strong><p className="mt-1 text-xs text-ink-3">Inspect work, share context, and request handoffs.</p></div><button onClick={onClose} aria-label="Close agents" className="rounded px-2 py-1 hover:bg-hover">×</button></header>
    <div className="flex flex-wrap items-center gap-3 border-b border-line p-3">
      <div className="flex gap-1" role="group" aria-label="Agent scope">{['workspace', 'device'].map(value => <button key={value} aria-pressed={scope === value} onClick={() => { setScope(value); setRecipient(null); setComposing(false); }} className={`rounded-lg px-3 py-2 text-xs ${scope === value ? 'bg-hover-2 text-ink' : 'text-ink-2 hover:bg-hover'}`}>{value === 'workspace' ? 'This workspace' : 'All local Graffs'}</button>)}</div>
      <label className="flex items-center gap-2 text-xs text-ink-3"><input type="checkbox" checked={showIdle} onChange={e => setShowIdle(e.target.checked)} />Show idle agents</label>
    </div>
    <div ref={content} className="min-h-0 flex-1 overflow-y-auto p-4">
      <div className="mx-auto w-full max-w-6xl space-y-4">
        {error && <p role="alert" className="text-sm text-ink-2">{error} <button className="underline" onClick={() => setRefresh(n => n + 1)}>Retry</button></p>}
        {!snapshot && !error && <p role="status" className="text-sm text-ink-3">Finding local Graffs…</p>}
        {snapshot && !selected && !agents.length && <div className="rounded-xl border border-dashed border-line p-6"><p className="text-sm text-ink-2">No {showIdle ? 'connected' : 'working'} Graffs {scope === 'workspace' ? 'in this workspace' : 'on this device'}.</p><p className="mt-2 text-xs text-ink-3">{!showIdle && connected.length > 0 ? 'Connected sessions are waiting for input. Show idle agents to inspect or message them.' : 'Start a Graff session to coordinate.'}</p></div>}
        {!selected && <ul className="grid gap-3" style={{ gridTemplateColumns: fullWidth ? 'repeat(auto-fit, minmax(min(100%, 280px), 1fr))' : 'minmax(0, 1fr)' }}>{agents.map(agent => <AgentCard key={agentKey(agent)} agent={agent} showWorkspace={scope === 'device'} onSelect={() => choose(agent)} />)}</ul>}
        {selected && <>
          <button aria-label="Back to all agents" className="rounded-lg px-2 py-1 text-xs hover:bg-hover" onClick={() => { setRecipient(null); setComposing(false); }}>← Agents</button>
          <section aria-label="Selected agent" className="space-y-3 rounded-xl border border-line bg-surface p-4">
            <div className="flex flex-wrap items-center gap-3"><h2 className="min-w-0 flex-1 break-words text-base font-medium">{agentName(selected)}</h2><AgentStatus status={selected.status} /></div>
            <p className="whitespace-pre-wrap break-words text-sm text-ink-2">{selected.task || 'No task published'}</p>
            <div className="flex flex-wrap gap-2"><button onClick={() => compose('message')} aria-expanded={composing && draft.kind === 'message'} className="rounded-lg bg-hover-2 px-3 py-2 text-xs">Message this Graff…</button><button onClick={() => compose('handoff')} aria-expanded={composing && draft.kind === 'handoff'} className="rounded-lg border border-line px-3 py-2 text-xs hover:bg-hover">Request handoff</button></div>
            <details className="text-xs text-ink-3"><summary className="cursor-pointer">Session details</summary><p className="mt-2 break-words">{selected.workspace}</p><p className="mt-2 tabular-nums">{selected.resources ? `${selected.resources.rssMiB.toFixed(1)} MiB · ${selected.resources.cpuPercent === null ? 'CPU sampling…' : `${selected.resources.cpuPercent.toFixed(1)}% CPU`}` : 'Resource measurements unavailable'}</p><p className="mt-1">Graff process only; shared workers and GPU are not attributed.</p></details>
          </section>
          {composing && <form className="space-y-3 rounded-xl border border-line p-4" onSubmit={e => { e.preventDefault(); void submit(); }}>
            <div className="flex items-center gap-2"><label className="min-w-0 flex-1 truncate text-xs text-ink-2">To {agentName(selected)}</label><button type="button" onClick={() => setComposing(false)} className="rounded px-2 py-1 text-xs hover:bg-hover">Hide composer</button></div>
            <textarea ref={input} aria-label="Message to Graff" value={draft.text} disabled={draft.sending} onChange={e => updateDraft(draftKey, { text: e.target.value })} maxLength={8192} rows={3} placeholder={draft.kind === 'handoff' ? 'Describe the work, relevant context, and what you need from this agent…' : 'Ask a peer or share context…'} className="w-full resize-y rounded-xl border border-line bg-surface p-3 text-sm outline-none focus:border-accent" />
            <div className="flex flex-wrap items-center gap-2"><select aria-label="Coordination type" disabled={draft.sending} value={draft.kind} onChange={e => updateDraft(draftKey, { kind: e.target.value })} className="rounded-lg bg-hover p-2 text-xs"><option value="message">Message</option><option value="handoff">Handoff request</option></select><button type="submit" disabled={!draft.text.trim() || draft.sending || !!error} className="ml-auto rounded-lg bg-hover-2 px-3 py-2 text-sm disabled:opacity-40">{draft.sending ? 'Queuing…' : 'Send to Graff'}</button></div>
            <p className="text-xs text-ink-3">Messages arrive at the recipient’s next step.{draft.kind === 'handoff' ? ' A handoff is a request, not a transfer of ownership or confirmation of acceptance.' : ''}</p>
          </form>}
          {draft.notice && <p role={draft.failed ? 'alert' : 'status'} className="rounded-lg border border-line p-3 text-xs text-ink-2">{draft.notice}</p>}
          <SubagentActivity key={agentKey(selected)} root={root} parent={selected} scope={scope} request={request} />
        </>}
        {!!messages.length && <details aria-label="Peer messages" className="space-y-3"><summary className="cursor-pointer text-xs font-medium text-ink-3">Coordination history{selected ? ' with this Graff' : ''} · {messages.length}</summary>{messages.map((message, i) => <article key={`${message.ts_ms}:${i}`} className="rounded-xl border border-line p-3">
          <div className="flex items-center gap-2 text-[11px] text-ink-3"><span className="min-w-0 flex-1 truncate">{message.from_user ? 'You' : name(message.from_session)} → {name(message.to)}</span><time>{new Date(message.ts_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time></div>
          {message.kind === 'handoff' && <span className="text-xs text-accent">Handoff request</span>}<p className="mt-2 whitespace-pre-wrap break-words text-sm">{message.text}</p>
        </article>)}</details>}
      </div>
    </div>
  </aside>;
  return fullWidth ? pane : <ResizableReviewPane label="agents" defaultWidth={440}>{pane}</ResizableReviewPane>;
}

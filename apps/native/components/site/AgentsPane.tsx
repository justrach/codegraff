'use client';
import { useEffect, useRef, useState } from 'react';
import { agentKey, agentName, agentRequest, type AgentSnapshot, type LocalAgent, type PeerMessage } from '@/lib/agents';
import ResizableReviewPane from './ResizableReviewPane';
import SubagentActivity from './SubagentActivity';


function talkLine(message: PeerMessage, name: (session: string) => string) {
  return <article className="rounded-xl border border-line p-3">
    <div className="flex items-center gap-2 text-[11px] text-ink-3"><span className="min-w-0 flex-1 truncate">{message.from_user ? 'You' : name(message.from_session)} → {name(message.to)}</span><time>{new Date(message.ts_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time></div>
    {message.kind === 'handoff' && <span className="text-xs text-accent">Handoff request</span>}<p className="mt-2 whitespace-pre-wrap break-words text-sm">{message.text}</p>
  </article>;
}

export default function AgentsPane({ root, onClose, request = agentRequest }: { root?: string; onClose(): void; request?: typeof agentRequest }) {
  const [scope, setScope] = useState('workspace');
  const [showIdle, setShowIdle] = useState(false);
  const [snapshot, setSnapshot] = useState<AgentSnapshot | null>(null);
  const [error, setError] = useState('');
  const [recipient, setRecipient] = useState<LocalAgent | null>(null);
  const [text, setText] = useState('');
  const [kind, setKind] = useState('message');
  const [sending, setSending] = useState(false);
  const [notice, setNotice] = useState('');
  const [refresh, setRefresh] = useState(0);
  const [composing, setComposing] = useState(false);
  const content = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { setRecipient(null); setNotice(''); setText(''); }, [root]);
  useEffect(() => {
    if (!snapshot || !recipient || snapshot.agents.some(agent => agentKey(agent) === agentKey(recipient))) return;
    setRecipient(null); setNotice(''); setText(''); setComposing(false);
  }, [snapshot, recipient]);
  useEffect(() => {
    let disposed = false, timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    setSnapshot(null); setError('');
    const poll = async () => {
      try {
        if (document.visibilityState !== 'hidden') {
          const data = await request(root, { action: 'list', scope }, controller.signal);
          if (!disposed) { setSnapshot(data); setError(''); }
        }
      } catch (e) { if (!disposed) setError(e instanceof Error ? e.message : 'Agents unavailable'); }
      finally { if (!disposed) timer = setTimeout(poll, 5000); }
    };
    void poll();
    return () => { disposed = true; controller.abort(); clearTimeout(timer); };
  }, [root, scope, refresh, request]);
  const connected = snapshot?.agents ?? [];
  const agents = connected.filter(agent => showIdle || agent.status === 'working');
  const selected = connected.find(a => recipient && agentKey(a) === agentKey(recipient));
  const name = (session: string) => connected.find(a => a.session === session)?.title || session || 'Workspace';
  const choose = (agent: LocalAgent) => { setRecipient(agent); setNotice(''); setComposing(false); content.current?.scrollTo({top:0}); };
  const submit = async () => {
    if (!selected || !text.trim() || sending) return;
    setSending(true); setNotice('');
    try {
      await request(root, { action: 'send', target: selected.session, startId: selected.startId, text, kind });
      setText(''); setNotice('Queued · Graff will read this at its next step.');
    } catch (e) { setNotice(e instanceof Error ? e.message : 'Message could not be queued'); }
    finally { setSending(false); }
  };
  return <ResizableReviewPane label="agents" defaultWidth={440}>
    <aside aria-label="Agents panel" className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden rounded-[14px] border border-line bg-page text-ink">
      <header className="flex items-center gap-2 border-b border-line p-4"><strong className="flex-1">Agents <span className="text-ink-3 font-normal">{snapshot ? agents.length : ''}</span></strong><button onClick={onClose} aria-label="Close agents" className="rounded px-2 hover:bg-hover">×</button></header>
      <div className="flex gap-1 border-b border-line p-3" role="group" aria-label="Agent scope">
        {['workspace', 'device'].map(value => <button key={value} aria-pressed={scope === value} onClick={() => { setScope(value); setRecipient(null); }} className={`rounded-lg px-3 py-2 text-xs ${scope === value ? 'bg-hover-2 text-ink' : 'text-ink-2 hover:bg-hover'}`}>{value === 'workspace' ? 'This workspace' : 'All local Graffs'}</button>)}
      </div>
      <label className="flex items-center gap-2 border-b border-line px-3 py-2 text-xs text-ink-3"><input type="checkbox" checked={showIdle} onChange={e => setShowIdle(e.target.checked)} />Show idle agents</label>
      <div ref={content} className="min-h-0 flex-1 overflow-y-auto p-3 space-y-4">
        {error && <p role="alert" className="text-sm text-ink-2">{error} <button className="underline" onClick={() => setRefresh(n => n + 1)}>Retry</button></p>}
        {!snapshot && !error && <p role="status" className="text-sm text-ink-3">Finding local Graffs…</p>}
        {snapshot && !selected && !agents.length && <p className="text-sm text-ink-3">No {showIdle ? 'connected' : 'active'} Graffs {scope === 'workspace' ? 'in this workspace' : 'on this laptop'}.{!showIdle && connected.length > 0 ? ' Show idle agents to see connected sessions waiting for input.' : ' Start a Graff session to coordinate.'}</p>}
        {!selected && <ul className="space-y-2">{agents.map(agent => <li key={agentKey(agent)}><button onClick={() => choose(agent)} aria-pressed={false} className="w-full rounded-xl border border-line p-3 text-left hover:bg-hover">
          <span className="flex items-center gap-2"><span className="min-w-0 flex-1 truncate text-sm font-medium">{agentName(agent)}</span><span className="text-xs text-ink-3">{agent.status === 'working' ? 'Working' : agent.status === 'waiting' ? 'Waiting' : 'Connected'}</span></span>
          <span className="mt-1 block text-xs text-ink-2 break-words">{agent.task || 'No task published'}</span>
          {snapshot?.messages.filter(m => m.to === agent.session || m.from_session === agent.session).slice(-1).map(m => <span key={m.ts_ms} className="mt-2 block truncate text-xs text-ink-3">{m.from_user ? 'You' : name(m.from_session)} → {name(m.to)}: {m.text}</span>)}
          {scope === 'device' && <span title={agent.workspace} className="mt-1 block truncate text-xs text-ink-3">{agent.workspace}</span>}
          <span title="Graff process only; shared workers and GPU are not attributed" className="mt-2 block text-[11px] text-ink-3 tabular-nums">{agent.resources ? `${agent.resources.rssMiB.toFixed(1)} MiB · ${agent.resources.cpuPercent === null ? 'CPU sampling…' : `${agent.resources.cpuPercent.toFixed(1)}% CPU`}` : 'Resource measurements unavailable'}</span>
        </button></li>)}</ul>}
        {selected && <><div className="flex min-w-0 items-center gap-3 text-xs"><button aria-label="Back to all agents" className="shrink-0 rounded-lg px-2 py-1 hover:bg-hover" onClick={() => setRecipient(null)}>← Agents</button><strong className="truncate">{agentName(selected)}</strong></div>
          {!!snapshot?.messages.filter(m => m.to === selected.session || m.from_session === selected.session).length && <section aria-label="Recent coordination" className="space-y-2"><h3 className="text-xs font-medium text-ink-2">How they talk</h3>{snapshot.messages.filter(m => m.to === selected.session || m.from_session === selected.session).slice(-8).map((message, i) => <div key={`${message.ts_ms}:${i}`}>{talkLine(message, name)}</div>)}</section>}
          <SubagentActivity key={agentKey(selected)} root={root} parent={selected} scope={scope} request={request} /></>}
        {!selected && !!snapshot?.messages.length && <section aria-label="Recent coordination" className="space-y-2"><h3 className="text-xs font-medium text-ink-2">How they talk</h3>{snapshot.messages.slice(-8).map((message, i) => <div key={`${message.ts_ms}:${i}`}>{talkLine(message, name)}</div>)}</section>}
        {!selected && !!snapshot?.messages.length && <details aria-label="Peer messages" className="space-y-3"><summary className="cursor-pointer text-xs font-medium text-ink-3">Coordination history</summary>{snapshot.messages.map((message, i) => <div key={`${message.ts_ms}:${i}`}>{talkLine(message, name)}</div>)}</details>}
      </div>
      {selected && <button className="shrink-0 border-t border-line px-4 py-3 text-left text-xs hover:bg-hover" aria-expanded={composing} onClick={() => setComposing(value => !value)}>{composing ? 'Hide message composer' : 'Message this Graff…'}</button>}
      {(!selected || composing) && <form className="space-y-2 border-t border-line p-3" onSubmit={e => { e.preventDefault(); void submit(); }}>
        <label className="block text-xs text-ink-2">To<select aria-label="Message recipient" value={selected ? agentKey(selected) : ''} onChange={e => { setRecipient(agents.find(a => agentKey(a) === e.target.value) ?? null); setNotice(''); }} className="ml-2 max-w-[85%] rounded-lg bg-hover px-2 py-1 text-ink"><option value="">Select a Graff</option>{selected && !agents.some(a => agentKey(a) === agentKey(selected)) && <option value={agentKey(selected)}>{agentName(selected)}</option>}{agents.map(a => <option key={agentKey(a)} value={agentKey(a)}>{agentName(a)}</option>)}</select></label>
        {recipient && !selected && <p className="text-xs text-ink-3">Recipient is unavailable in this view. Select another Graff or show idle agents.</p>}
        <textarea ref={input} aria-label="Message to Graff" value={text} onChange={e => setText(e.target.value)} maxLength={8192} rows={2} placeholder="Ask a peer, share context, or request a handoff…" className="w-full resize-y rounded-xl border border-line bg-surface p-3 text-sm outline-none focus:border-accent" />
        <div className="flex items-center gap-2"><select aria-label="Coordination type" value={kind} onChange={e => setKind(e.target.value)} className="rounded-lg bg-hover p-2 text-xs"><option value="message">Message</option><option value="handoff">Handoff request</option></select><button type="submit" disabled={!selected || !text.trim() || sending || !!error} className="ml-auto rounded-lg bg-hover-2 px-3 py-2 text-sm disabled:opacity-40">{sending ? 'Queuing…' : 'Send to Graff'}</button></div>
        {notice && <p role="status" className="text-xs text-ink-2">{notice}</p>}
        <p title="A handoff requests coordination, without transferring ownership. Profiler exports exclude message content and peer identities." className="text-[10px] text-ink-3">Messages arrive at the recipient’s next step.</p>
      </form>}
    </aside>
  </ResizableReviewPane>;
}

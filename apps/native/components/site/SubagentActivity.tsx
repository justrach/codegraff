'use client';
import { useEffect, useMemo, useState } from 'react';
import { agentRequest, agentKey, type LocalAgent, type ChildAgent, type ChildActivity } from '@/lib/agents';
import { applyAcpUpdate, emptyTurn, finishAcpTurn } from '@/lib/acp';
import { AssistantBody } from './ChatBubbles';

export default function SubagentActivity({root, parent, scope, request}: {root?: string; parent: LocalAgent; scope: string; request: typeof agentRequest}) {
  const [children, setChildren] = useState<ChildAgent[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [activity, setActivity] = useState<ChildActivity | null>(null);
  const [error, setError] = useState('');
  const [loaded, setLoaded] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [limited, setLimited] = useState(false);
  const key = agentKey(parent);
  useEffect(() => {
    let disposed = false, timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    setChildren([]); setLoaded(false); setLimited(false); setError(''); setSelected(null); setActivity(null);
    const poll = async () => {
      try {
        if (document.visibilityState !== 'hidden') {
          const result = await request(root, {action:'children', scope, target:parent.session, startId:parent.startId}, controller.signal);
          if (!disposed) { setChildren(result.children ?? []); setLimited(!!result.truncated); setLoaded(true); setError(''); }
        }
      } catch (e) { if (!disposed) setError(e instanceof Error ? e.message : 'Sub-agents unavailable'); }
      finally { if (!disposed) timer = setTimeout(poll, 3000); }
    };
    void poll();
    return () => { disposed = true; controller.abort(); clearTimeout(timer); };
  }, [root, key, parent.session, parent.startId, scope, request, refresh]);
  const [detailError, setDetailError] = useState('');
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    setActivity(null); setDetailError('');
    if (!selected) return;
    let disposed = false, timer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    const poll = async () => {
      let done = false;
      try {
        if (document.visibilityState !== 'hidden') {
          const result: ChildActivity = await request(root, {action:'activity', scope, target:parent.session, startId:parent.startId, child:selected}, controller.signal);
          if (result.agent.id !== selected) throw new Error('Sub-agent selection changed. Select it again.');
          if (!disposed) { setActivity(result); setDetailError(''); done = result.agent.status !== 'working'; }
        }
      } catch (e) { if (!disposed) setDetailError(e instanceof Error ? e.message : 'Activity unavailable'); }
      finally { if (!disposed && !done) timer = setTimeout(poll, 1000); }
    };
    void poll();
    return () => { disposed = true; controller.abort(); clearTimeout(timer); };
  }, [root, key, parent.session, parent.startId, scope, selected, request, retry]);
  const turn = useMemo(() => {
    if (!activity || activity.agent.id !== selected) return null;
    let value = emptyTurn();
    for (const line of activity.updates) if ('method' in line && line.method === 'session/update' && line.params.sessionId === activity.agent.id) value = applyAcpUpdate(value, line.params.update);
    if (activity.agent.status !== 'working') {
      if (activity.response && !value.text.endsWith(activity.response)) value = applyAcpUpdate(value, {sessionUpdate:'agent_message_chunk', content:{type:'text', text:`${value.text ? '\n\n' : ''}${activity.response}`}});
      value = finishAcpTurn(value);
      if (activity.agent.status === 'failed') value = {...value, status:'error', error:activity.response || 'Sub-agent failed.'};
    }
    // Snapshot replay time is not the child's execution time.
    return {...value, tools:value.tools.map(tool => ({...tool, startedAt:undefined, elapsedMs:undefined}))};
  }, [activity, selected]);
  return <section aria-label="Sub-agents" className="space-y-3 rounded-xl border border-line p-3">
    <h3 className="text-sm font-medium">Sub-agents</h3>
    {error ? <p role="alert" className="text-xs text-ink-2">{error} <button className="underline" onClick={() => setRefresh(n => n + 1)}>Retry</button></p>
      : !loaded ? <p role="status" className="text-xs text-ink-3">Finding sub-agents…</p>
      : !children.length ? <p className="text-xs text-ink-3">No sub-agent activity published by this session yet. Older Graff binaries do not publish this feed.</p> : null}
    {selected ? <select aria-label="Select sub-agent" className="w-full min-w-0 rounded-lg bg-hover p-2 text-xs text-ink" value={selected} onChange={e => setSelected(e.target.value)}>{!children.some(child => child.id === selected) && <option value={selected}>Selected sub-agent</option>}{children.map(child => <option key={child.id} value={child.id}>{child.label || 'Sub-agent'} · {child.status}</option>)}</select>
    : <div className="max-h-48 space-y-1 overflow-y-auto">{children.map(child => <button key={child.id} data-child-agent={child.id} onClick={() => setSelected(child.id)} className="w-full rounded-lg p-2 text-left text-xs hover:bg-hover">
      <span className="flex items-center gap-2"><span className="min-w-0 flex-1 truncate font-medium">{child.label || 'Sub-agent'}</span><span className="text-ink-3">{child.status === 'working' ? 'Working' : child.status === 'completed' ? 'Completed' : 'Failed'}</span></span>
      <span className="mt-1 block truncate text-ink-3" title={child.task}>{child.task}</span>
    </button>)}</div>}
    {limited && <p className="text-xs text-ink-3">Showing the most recent sub-agents.</p>}
    {selected && <section aria-label="Sub-agent activity" className="border-t border-line pt-3">
      <div className="mb-3 flex items-center gap-2 text-xs"><strong className="min-w-0 flex-1 truncate">{activity?.agent.label || children.find(c => c.id === selected)?.label || 'Activity'}</strong><span role="status" className="text-ink-3">{detailError ? 'Updates unavailable' : activity?.agent.status === 'working' ? 'Live' : activity ? activity.agent.status === 'completed' ? 'Completed' : 'Failed' : 'Loading…'}</span><button aria-label="Close sub-agent activity" onClick={() => setSelected(null)}>×</button></div>
      {detailError && <p role="alert" className="mb-3 text-xs text-ink-2">{detailError} <button className="underline" onClick={() => setRetry(n => n + 1)}>Retry</button></p>}
      {activity?.agent.truncated && <p className="mb-3 text-xs text-ink-3">Recent activity only. Older events or large outputs were shortened.</p>}
      <div className="max-h-[50vh] overflow-y-auto overscroll-contain [overflow-wrap:anywhere]">{turn && <AssistantBody key={selected} turn={turn} following={false} reasoningLabel="Reported reasoning" />}</div>
      <p className="mt-3 text-[10px] text-ink-3">Reported progress and tool activity. Opening this view does not send instructions.</p>
    </section>}
  </section>;
}

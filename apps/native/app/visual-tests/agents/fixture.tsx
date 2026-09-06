'use client';
import { useCallback, useState } from 'react';
import AgentsPane from '@/components/site/AgentsPane';
import { applyAppearance, type Appearance } from '@/lib/appearance';
export default function Fixture() {
  const [scenario, setScenario] = useState('connected');
  const [sent, setSent] = useState('');
  const request = useCallback(async (_root: string | undefined, params: Record<string, unknown>) => {
    if (scenario === 'error') throw new Error('Observer unavailable');
    if (params.action === 'send') { setSent(JSON.stringify(params)); return { delivery: 'queued' }; }
    return { agents: scenario === 'empty' ? [] : [
      { session: 'peer-a', title: 'Implement navigation', startId: '11', pid: 1, task: 'Refine keyboard navigation', workspace: '/demo/workspace', status: 'working', resources: { rssMiB: 20, cpuPercent: 1.2 } },
      ...(params.scope === 'device' ? [{ session: 'peer-b', title: 'Review accessibility', startId: '12', pid: 2, task: 'Check focus order', workspace: '/demo/second', status: 'waiting', resources: null }] : []),
    ], messages: [{ from_session: 'peer-a', to: 'peer-b', ts_ms: 1000, text: 'The navigation update is ready for review.', kind: 'handoff' }], delivery: 'Queued' };
  }, [scenario]);
  return <main className="flex h-screen flex-col bg-page text-ink">
    <nav className="flex gap-3 p-3">{['connected', 'empty', 'error'].map(value => <button key={value} data-agent-case={value} onClick={() => setScenario(value)}>{value}</button>)}{['light', 'dark', 'codegraff'].map(theme => <button key={theme} data-agent-theme={theme} onClick={() => applyAppearance(theme as Appearance)}>{theme}</button>)}</nav>
    <div className="flex min-h-0 flex-1 gap-3 p-3"><div className="flex-1 min-w-0 p-5"><h1>Workspace conversation</h1><p>The agent panel keeps coordination alongside your work.</p><output data-agent-sent className="break-all">{sent}</output></div><AgentsPane root="/demo/workspace" onClose={() => {}} request={request} /></div>
  </main>;
}

'use client';
import { agentName, type LocalAgent } from '@/lib/agents';

export function AgentStatus({ status }: { status: string }) {
  return <span className="inline-flex shrink-0 items-center gap-1.5 text-xs text-ink-3"><span aria-hidden="true" className={`h-1.5 w-1.5 rounded-full ${status === 'working' ? 'bg-accent' : 'bg-ink-3'}`} />{status === 'working' ? 'Working' : status === 'waiting' ? 'Waiting' : 'Connected'}</span>;
}

export default function AgentCard({ agent, showWorkspace, onSelect }: { agent: LocalAgent; showWorkspace: boolean; onSelect(): void }) {
  return <li className="min-w-0"><button onClick={onSelect} aria-pressed={false} className="flex h-full w-full flex-col gap-3 rounded-xl border border-line bg-surface p-4 text-left transition-colors hover:bg-hover focus-visible:outline focus-visible:outline-accent">
    <span className="flex w-full min-w-0 flex-wrap items-center gap-2"><span className="min-w-0 flex-1 truncate text-sm font-medium">{agentName(agent)}</span><AgentStatus status={agent.status} /></span>
    <span className="line-clamp-3 break-words text-sm text-ink-2">{agent.task || 'No task published'}</span>
    {showWorkspace && <span title={agent.workspace} className="block w-full truncate text-xs text-ink-3">{agent.workspace}</span>}
    <span className="mt-auto pt-1 text-xs text-ink-3">Inspect & coordinate →</span>
  </button></li>;
}

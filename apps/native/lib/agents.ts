export type LocalAgent = { session: string; startId: string; pid: number; title: string; task: string; workspace: string; status: string;
  resources?: { rssMiB: number; cpuPercent: number | null } | null };
export type PeerMessage = { from_session: string; to: string; text: string; ts_ms: number; from_user: boolean; kind?: string };
export type AgentSnapshot = { agents: LocalAgent[]; messages: PeerMessage[]; delivery: string };
export const agentKey = (agent: LocalAgent) => `${agent.pid}:${agent.startId}`;
export const agentName = (agent: LocalAgent) => agent.title || agent.session || 'Untitled Graff';
/** Working peers only — occupancy for the toolbar, never RSS/CPU. */
export function workingAgentCount(agents: { status: string }[] | undefined): number {
  return agents?.filter(agent => agent.status === 'working').length ?? 0;
}
export async function agentRequest(root: string | undefined, params: Record<string, unknown>, signal?: AbortSignal) {
  const res = await fetch('/api/agents', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root, ...params }), signal });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || 'Agents unavailable');
  return body;
}

export type ChildAgent = { id: string; label: string; task: string; status: 'working' | 'completed' | 'failed'; updatedAt: number; truncated: boolean };

/** Working and failed children belong on the composer dock; completed ones do not. */
export function composerChildren(children: ChildAgent[] | undefined): ChildAgent[] {
  return (children ?? []).filter(child => child.status !== 'completed');
}

export function childElapsed(updatedAt: number, now = Date.now()): string {
  const start = updatedAt > 0 && updatedAt < 1e12 ? updatedAt * 1000 : updatedAt;
  const seconds = Math.max(0, Math.floor((now - start) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m ${seconds % 60}s`;
}
export type ChildActivity = { agent: ChildAgent; updates: import('./acp').JsonRpcLine[]; response: string };

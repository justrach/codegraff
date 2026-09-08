export type LocalAgent = { session: string; startId: string; pid: number; title: string; task: string; workspace: string; status: string;
  resources?: { rssMiB: number; cpuPercent: number | null } | null };
export type PeerMessage = { from_session: string; to: string; text: string; ts_ms: number; from_user: boolean; kind?: string };
export type AgentSnapshot = { agents: LocalAgent[]; messages: PeerMessage[]; delivery: string };
export const agentKey = (agent: LocalAgent) => `${agent.pid}:${agent.startId}`;
export const agentName = (agent: LocalAgent) => agent.title || agent.session || 'Untitled Graff';
export async function agentRequest(root: string | undefined, params: Record<string, unknown>, signal?: AbortSignal) {
  const res = await fetch('/api/agents', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ root, ...params }), signal });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || 'Agents unavailable');
  return body;
}

export type ChildAgent = { id: string; label: string; task: string; status: 'working' | 'completed' | 'failed'; updatedAt: number; truncated: boolean };
export type ChildActivity = { agent: ChildAgent; updates: import('./acp').JsonRpcLine[]; response: string };

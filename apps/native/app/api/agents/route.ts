import path from 'node:path';
import { existsSync } from 'node:fs';
import { resolveRoot } from '@/lib/server-root';
import type { AgentSnapshot } from '@/lib/agents';
// Shared with Electron's opt-in profiler; all peer discovery stays in Graff.
import { observeAgents, agentSampler } from '../../../electron/agent-observer.cjs';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
const sample = agentSampler();
export async function POST(req: Request) {
  try {
    if (Number(req.headers.get('content-length')) > 16384) return Response.json({ error: 'Message too large' }, { status: 413 });
    const body = await req.json();
    const resolved = resolveRoot(typeof body.root === 'string' ? body.root : undefined);
    if ('error' in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
    if (!['list', 'send', 'children', 'activity'].includes(body.action)) return Response.json({ error: 'Unknown agents action' }, { status: 400 });
    if (body.action === 'send' && (typeof body.text !== 'string' || body.text.length > 8192)) return Response.json({ error: 'Message too large' }, { status: 400 });
    const built = path.resolve(process.cwd(), '../../zig-out/bin/graff');
    const binary = process.env.GRAFF_BIN || (existsSync(built) ? built : 'graff');
    const result = await observeAgents(binary, resolved.root, { action: body.action, scope: body.scope === 'device' ? 'device' : 'workspace',
      ...(body.action === 'children' || body.action === 'activity' ? { target: body.target, startId: body.startId, child: body.child } : {}),
      ...(body.action === 'send' ? { target: body.target, startId: body.startId, text: body.text, kind: body.kind } : {}) });
    if (body.action === 'list') (result as AgentSnapshot).agents = await sample(result.agents);
    return Response.json(result, { headers: { 'cache-control': 'no-store' } });
  } catch (error) { return Response.json({ error: error instanceof Error ? error.message : 'Agents unavailable' }, { status: 502 }); }
}

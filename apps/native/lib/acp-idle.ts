/** Park an idle `graff acp` child after a quiet period. Off by default:
 *  an open GUI tab keeps its worker so a background command can still
 *  resume the turn when it exits. Set `GRAFF_ACP_IDLE_MS` to shed it;
 *  the session file stays on disk and the next bootstrap uses `--resume`.
 *
 *  Do not park while a prompt, session/idle subscriber, or other busy
 *  callback is live — stream close alone is not ownership of background work. */

export type ParkedWorker = {
  resume: string | null;
  model: string | null;
  cwd: string;
  yolo: boolean;
  mcp: boolean;
};

const g = globalThis as typeof globalThis & {
  __graffAcpIdle?: Map<string, ReturnType<typeof setTimeout>>;
  __graffAcpParked?: Map<string, ParkedWorker>;
};
const timers = (g.__graffAcpIdle ??= new Map());
const parked = (g.__graffAcpParked ??= new Map());

export function idleMs(): number {
  const raw = process.env.GRAFF_ACP_IDLE_MS;
  if (raw === undefined || raw === "") return 0;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return 0;
  return n;
}

/** Array.map passes an index as the second argument; only an explicit true parks. */
export function keepPark(flag: unknown): boolean {
  return flag === true;
}

export function cancelIdle(chat: string): void {
  const timer = timers.get(chat);
  if (timer) clearTimeout(timer);
  timers.delete(chat);
}

export function forgetPark(chat: string): void {
  cancelIdle(chat);
  parked.delete(chat);
}

export function parkedChats(): string[] {
  return [...new Set([...parked.keys(), ...timers.keys()])];
}

export function forgetParkMatching(prefix: string): void {
  for (const chat of parkedChats()) if (chat.startsWith(prefix)) forgetPark(chat);
}

export function takeParked(chat: string): ParkedWorker | undefined {
  cancelIdle(chat);
  const held = parked.get(chat);
  parked.delete(chat);
  return held;
}

/** Keep a crashed or otherwise-exited worker resumable. Dispose/reset still
 *  call forgetPark so a closed tab does not come back. */
export function parkNow(chat: string, snapshot: ParkedWorker): void {
  cancelIdle(chat);
  if (snapshot.resume) parked.set(chat, snapshot);
}

export function armIdle(chat: string, snapshot: ParkedWorker, kill: () => void, busy?: () => boolean): void {
  cancelIdle(chat);
  const wait = idleMs();
  if (wait <= 0) return;
  timers.set(chat, setTimeout(() => {
    timers.delete(chat);
    if (busy?.()) {
      armIdle(chat, snapshot, kill, busy);
      return;
    }
    parked.set(chat, snapshot);
    kill();
  }, wait));
}

export function parkCount(): number {
  return parked.size;
}

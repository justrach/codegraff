/** Record why an ACP slot was signaled so a 1h SIGTERM is not anonymous. */

export type TerminateReason =
  | "idle-park"
  | "dispose"
  | "dispose-page"
  | "shutdown"
  | "session-writer"
  | "bootstrap-replace"
  | "stuck-cancel";

export type Termination = {
  chat: string;
  reason: TerminateReason;
  turnActive: boolean;
  childAgeMs: number;
  signal: "SIGTERM" | "EOF";
};

const g = globalThis as typeof globalThis & { __graffAcpTerminations?: Termination[] };
const log = (g.__graffAcpTerminations ??= []);

export function recordTermination(entry: Termination): Termination {
  log.push(entry);
  if (log.length > 32) log.shift();
  return entry;
}

export function recentTerminations(): readonly Termination[] {
  return log;
}

export function resetTerminationsForTest(): void {
  log.length = 0;
}

export function shouldReapPage(event: { persisted?: boolean }): boolean {
  return event.persisted !== true;
}

export function formatTermination(entry: Termination): string {
  return `acp terminate chat=${entry.chat} reason=${entry.reason} turnActive=${entry.turnActive} ageMs=${entry.childAgeMs} signal=${entry.signal}`;
}

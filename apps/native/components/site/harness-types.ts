import type { AssistantTurn } from "@/lib/acp";
export type Msg =
  | { id: number; role: "user"; text: string }
  | { id: number; role: "assistant"; turn: AssistantTurn };

/** `model` is what this tab's own agent was spawned with; the harness-level
 * model is only the default a new tab inherits. `cwd` is the workspace the
 * tab's agent runs in — fixed at spawn, like the model. */
export type Chat = { id: number; title: string | null; messages: Msg[]; model?: string; session?: string; cwd?: string;
  /** The model named this tab from its first prompt: the session poller,
   * which reads graff's own saved title, must leave it alone. */
  titledByModel?: boolean };

export function newPageToken(): string {
  return Math.random().toString(36).slice(2, 10);
}

/** A fresh tab's graff session name. Not `session-…`: that prefix is what the
 * REPL's auto-title renames, and a tab needs a name that stays put so the
 * sidebar row and the running agent keep pointing at the same file. */
export function newSessionName(): string {
  return `native-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}


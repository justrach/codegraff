import type { ModelChoice } from "./acp-client";

/** Label the composer pill. A live key is never replaced by catalog[0]. */
export function resolveComposerModel(catalog: ModelChoice[], modelKey?: string | null): ModelChoice {
  if (modelKey) return catalog.find((m) => m.key === modelKey) ?? { key: modelKey, name: modelKey };
  return catalog[0] ?? { key: "", name: "Loading graff models…" };
}

/** Display key: this chat's ACP model. Global inherit is only for a tab with no agent yet. */
export function liveComposerKey(
  threadModel: string | undefined,
  globalModel: string | null | undefined,
  hasAgent: boolean,
): string | undefined {
  if (threadModel) return threadModel;
  if (hasAgent) return undefined;
  return globalModel ?? undefined;
}

/** A confirmed or in-flight pick owns the pill until the new agent answers. */
export function paneComposerKey(
  threadModel: string | undefined,
  globalModel: string | null | undefined,
  hasAgent: boolean,
  pending?: { chatId: number; key: string } | null,
  chatId?: number,
): string | undefined {
  if (pending && chatId === pending.chatId) return pending.key;
  return liveComposerKey(threadModel, globalModel, hasAgent);
}

/** Catalog refresh must not overwrite the chat the user is switching. */
export function catalogMayWriteChatModel(
  chatId: number,
  pending?: { chatId: number } | null,
): boolean {
  return pending?.chatId !== chatId;
}

/** An existing agent's `current` is that chat's model, not the global inherit. */
export function catalogMayWriteGlobalKey(hasAgent: boolean): boolean {
  return !hasAgent;
}

export function shouldConfirmModelSwitch(messageCount: number, running: boolean): boolean {
  return messageCount > 0 || running;
}

export function modelDisplayName(models: { key: string; name: string }[], key: string | null | undefined): string {
  return models.find((m) => m.key === key)?.name ?? key ?? "the current model";
}

/** Pill after a `graff/models` reply. `current` is the agent; the catalog only prettifies it. */
export function pillFromAcp(
  models: ModelChoice[],
  current: string | null,
  globalKey?: string | null,
  hasAgent = true,
): ModelChoice {
  return resolveComposerModel(models, liveComposerKey(current ?? undefined, globalKey, hasAgent));
}

export function sameModels(a: ModelChoice[], b: ModelChoice[]): boolean {
  return a.length === b.length && a.every((m, i) => m.key === b[i]?.key && m.name === b[i]?.name);
}

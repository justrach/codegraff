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

/** Pill after a `graff/models` reply. `current` is the agent; the catalog only prettifies it. */
export function pillFromAcp(
  models: ModelChoice[],
  current: string | null,
  globalKey?: string | null,
  hasAgent = true,
): ModelChoice {
  return resolveComposerModel(models, liveComposerKey(current ?? undefined, globalKey, hasAgent));
}

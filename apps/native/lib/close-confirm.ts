/** The tab-close confirmation: closing a tab stops its `graff acp` worker,
 * so the first close asks. "Don't ask again" remembers the choice forever;
 * a tab with no worker never asks because there is nothing to stop. */

export const CLOSE_DONT_ASK_KEY = "graff.close.dont-ask";

export function parseCloseDontAsk(value: unknown): boolean {
  return value === true || value === "true" || value === "1";
}

export type CloseAskStorage = Pick<Storage, "getItem" | "setItem">;

export function readCloseDontAsk(storage?: CloseAskStorage | null): boolean {
  try {
    return parseCloseDontAsk(storage?.getItem(CLOSE_DONT_ASK_KEY));
  } catch {
    return false;
  }
}

export function writeCloseDontAsk(storage: CloseAskStorage | null | undefined, value: boolean): void {
  try {
    storage?.setItem(CLOSE_DONT_ASK_KEY, value ? "true" : "false");
  } catch {
    /* Optional storage; the prompt simply asks again next time. */
  }
}

/** How many of the closing tabs own a live worker. Tabs that never
 * bootstrapped an agent (a fresh desktop tab before its first prompt)
 * close silently. */
export function closeWorkerCount(ids: number[], hasWorker: (id: number) => boolean): number {
  return ids.filter(hasWorker).length;
}

export function shouldConfirmTabClose(args: { dontAskAgain: boolean; closingWorkers: number }): boolean {
  return !args.dontAskAgain && args.closingWorkers > 0;
}

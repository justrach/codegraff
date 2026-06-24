const inFlightPromptSubmitKeys = new Set<string>();

export function beginPromptSubmit(promptDraftKey: string | null): boolean {
  if (promptDraftKey == null) {
    return false;
  }
  if (inFlightPromptSubmitKeys.has(promptDraftKey)) {
    return false;
  }
  inFlightPromptSubmitKeys.add(promptDraftKey);
  return true;
}

export function finishPromptSubmit(promptDraftKey: string | null): void {
  if (promptDraftKey == null) {
    return;
  }
  inFlightPromptSubmitKeys.delete(promptDraftKey);
}

export function resetPromptSubmitLocksForTest(): void {
  inFlightPromptSubmitKeys.clear();
}

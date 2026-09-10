/** A queued animation-frame focus must not override a newer chat (#842). */
export function deferredFocusStillActive(activeId: number, capturedId: number): boolean {
  return activeId === capturedId;
}

export const tracesPrefKey = "graff-show-traces";
export const tracesPrefEvent = "graff-traces-pref";
export const tracesOpenEvent = "graff-open-traces";

export function tracesWanted(): boolean {
  try { return localStorage.getItem(tracesPrefKey) === "1"; } catch { return false; }
}

export function setTracesWanted(on: boolean): void {
  try { localStorage.setItem(tracesPrefKey, on ? "1" : "0"); } catch { /* optional */ }
  window.dispatchEvent(new Event(tracesPrefEvent));
}

export function openTraces(): void {
  window.dispatchEvent(new Event(tracesOpenEvent));
}

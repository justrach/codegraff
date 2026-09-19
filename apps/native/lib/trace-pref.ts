export const tracesOpenEvent = "graff-open-traces";

export function openTraces(): void {
  window.dispatchEvent(new Event(tracesOpenEvent));
}

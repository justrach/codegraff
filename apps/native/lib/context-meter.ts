export type ContextMeter = { used: number; window: number };
export function parseContextMeter(value: unknown): ContextMeter | undefined {
  const m = value as Partial<ContextMeter> | null;
  return m && typeof m.used === "number" && Number.isFinite(m.used) && m.used >= 0 &&
    typeof m.window === "number" && Number.isFinite(m.window) && m.window > 0
    ? { used: m.used, window: m.window } : undefined;
}
export function contextRemaining(meter?: ContextMeter): number | undefined {
  const m = parseContextMeter(meter);
  return m ? Math.round(Math.max(0, Math.min(1, 1 - m.used / m.window)) * 100) : undefined;
}

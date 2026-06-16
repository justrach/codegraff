const RELATIVE_TIME_UNITS = [
  { thresholdMs: 365 * 24 * 60 * 60 * 1000, label: 'y' },
  { thresholdMs: 30 * 24 * 60 * 60 * 1000, label: 'mo' },
  { thresholdMs: 7 * 24 * 60 * 60 * 1000, label: 'w' },
  { thresholdMs: 24 * 60 * 60 * 1000, label: 'd' },
  { thresholdMs: 60 * 60 * 1000, label: 'h' },
  { thresholdMs: 60 * 1000, label: 'm' },
  { thresholdMs: 1000, label: 's' },
] as const

export function formatRelativeTimestamp(value: string | null): string | null {
  if (value == null || value === '') {
    return null
  }

  const trimmed = value.trim()
  // Accept epoch-millis strings (what the runtime sends) as well as ISO dates.
  const timestamp = /^\d+$/.test(trimmed)
    ? new Date(Number(trimmed))
    : new Date(trimmed)
  if (Number.isNaN(timestamp.getTime())) {
    return null
  }

  const ageMs = Math.abs(Date.now() - timestamp.getTime())
  for (const unit of RELATIVE_TIME_UNITS) {
    if (ageMs >= unit.thresholdMs) {
      return `${Math.round(ageMs / unit.thresholdMs)}${unit.label}`
    }
  }

  return '0s'
}

export function formatDurationLabel(durationMs: number): string {
  const totalSeconds = Math.max(0, Math.floor(durationMs / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;

  if (minutes === 0) {
    return `${seconds}s`;
  }

  return `${minutes}m ${seconds}s`;
}

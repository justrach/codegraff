import { getCurrentWindow } from '@tauri-apps/api/window'
import type { MouseEvent } from 'react'
import { hasTauriInternals } from './tauri'

export function handleWindowDragStart(event: MouseEvent<HTMLElement>): void {
  if (event.button !== 0 || !hasTauriInternals()) {
    return
  }

  try {
    void getCurrentWindow().startDragging()
  } catch {
    // Mer-hosted windows do not expose Tauri's window API.
  }
}

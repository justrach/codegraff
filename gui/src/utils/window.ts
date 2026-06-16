import { getCurrentWindow } from '@tauri-apps/api/window'
import type { MouseEvent } from 'react'

export function handleWindowDragStart(event: MouseEvent<HTMLElement>): void {
  if (event.button !== 0) {
    return
  }

  void getCurrentWindow().startDragging()
}

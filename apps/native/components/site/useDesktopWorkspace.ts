import { useEffect, useRef } from 'react';
import { desktop } from '@/lib/desktop';

export function useDesktopWorkspace(ready: boolean, open: (target: { cwd: string; file?: string }) => void) {
  const ref = useRef(open); ref.current = open;
  useEffect(() => {
    if (ready) return desktop()?.workspaceSubscribe?.(target => ref.current(target));
  }, [ready]);
}

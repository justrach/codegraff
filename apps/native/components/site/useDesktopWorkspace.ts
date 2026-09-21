import { useEffect, useRef } from 'react';
import { desktop } from '@/lib/desktop';

export function useDesktopWorkspace(ready: boolean, open: (target: { cwd: string; file?: string }) => void) {
  const ref = useRef(open); ref.current = open;
  useEffect(() => {
    const onOpen = (event: Event) => {
      const cwd = (event as CustomEvent<{ cwd?: string }>).detail?.cwd;
      if (typeof cwd === "string" && cwd) ref.current({ cwd });
    };
    window.addEventListener("graff-open-workspace", onOpen);
    return () => window.removeEventListener("graff-open-workspace", onOpen);
  }, []);
  useEffect(() => {
    if (ready) return desktop()?.workspaceSubscribe?.(target => ref.current(target));
  }, [ready]);
}

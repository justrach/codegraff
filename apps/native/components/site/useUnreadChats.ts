import { useCallback, useEffect, useRef, useState } from "react";

/** Completion is unread only when its conversation is not on screen. */
export function completedUnread(current: ReadonlySet<number>, id: number, visible: readonly number[], present: readonly number[]) {
  const next = new Set([...current].filter(key => present.includes(key)));
  if (present.includes(id) && !visible.includes(id)) next.add(id);
  for (const key of visible) next.delete(key);
  return next;
}

export function useUnreadChats(present: number[], visible: number[]) {
  const [unread, setUnread] = useState<ReadonlySet<number>>(new Set());
  const state = useRef({ present, visible });
  state.current = { present, visible };
  const started = useCallback((id: number) => {
    setUnread(current => { if (!current.has(id)) return current; const next = new Set(current); next.delete(id); return next; });
  }, []);
  const completed = useCallback((id: number) => {
    const viewed = document.visibilityState === "hidden" ? [] : state.current.visible;
    setUnread(current => completedUnread(current, id, viewed, state.current.present));
  }, []);
  const visibleKey = visible.join(","), presentKey = present.join(",");
  useEffect(() => {
    const viewed = () => {
      if (document.visibilityState === "hidden") return;
      setUnread(current => {
        const next = completedUnread(current, -1, state.current.visible, state.current.present);
        return next.size === current.size ? current : next;
      });
    };
    viewed();
    document.addEventListener("visibilitychange", viewed);
    window.addEventListener("focus", viewed);
    return () => { document.removeEventListener("visibilitychange", viewed); window.removeEventListener("focus", viewed); };
  }, [visibleKey, presentKey]);
  return { unread, started, completed };
}

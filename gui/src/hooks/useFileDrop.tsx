import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
} from "react";
import type { ReactNode, RefObject } from "react";
import { getCurrentWebview } from "@tauri-apps/api/webview";

interface DropZone {
  id: string;
  ref: RefObject<HTMLElement | null>;
  onDrop: (paths: string[]) => void;
}

interface DragDropContextValue {
  register: (zone: DropZone) => () => void;
  isDragging: boolean;
  activeZoneId: string | null;
}

const DragDropContext = createContext<DragDropContextValue | null>(null);

export function DragDropProvider({ children }: { children: ReactNode }) {
  const zonesRef = useRef<Map<string, DropZone>>(new Map());
  const [isDragging, setIsDragging] = useState(false);
  const [activeZoneId, setActiveZoneId] = useState<string | null>(null);

  const resolveZoneId = useCallback(
    (position: { x: number; y: number }): string | null => {
      const zones = Array.from(zonesRef.current.values());
      if (zones.length === 0) {
        return null;
      }

      // Only consider zones that are actually on screen. Multiple composers can
      // be mounted at once (e.g. a hidden new-chat composer behind an active
      // chat), so filtering by visibility disambiguates the common case.
      const visibleZones = zones.filter((zone) => {
        const element = zone.ref.current as HTMLElement | null;
        if (element == null || element.offsetParent === null) {
          return false;
        }
        const rect = element.getBoundingClientRect();
        return (
          rect.width > 0 &&
          rect.height > 0 &&
          rect.bottom > 0 &&
          rect.right > 0 &&
          rect.top < window.innerHeight &&
          rect.left < window.innerWidth
        );
      });

      const candidates = visibleZones.length > 0 ? visibleZones : zones;

      // A single visible composer (landing / single chat) is unambiguous — route
      // to it without depending on coordinate mapping, which differs across
      // platforms and titlebar styles.
      if (candidates.length === 1) {
        return candidates[0].id;
      }

      // Multiple panes visible: hit-test the cursor. Tauri reports physical
      // pixels; the DOM works in CSS pixels.
      const dpr = window.devicePixelRatio || 1;
      const x = position.x / dpr;
      const y = position.y / dpr;

      for (const zone of candidates) {
        const element = zone.ref.current;
        if (element == null) {
          continue;
        }

        const rect = element.getBoundingClientRect();
        if (
          x >= rect.left &&
          x <= rect.right &&
          y >= rect.top &&
          y <= rect.bottom
        ) {
          return zone.id;
        }
      }

      return null;
    },
    [],
  );

  useEffect(() => {
    // Visual QA runs in a normal browser where Tauri's webview API is absent.
    if (import.meta.env.VITE_CODEGRAFF_QA_MOCK === "1") {
      return;
    }

    let isMounted = true;
    let unlisten: (() => void) | null = null;

    try {
      void getCurrentWebview()
        .onDragDropEvent((event) => {
          const payload = event.payload;
          if (import.meta.env.DEV) {
            console.debug("[file-drop] event", payload);
          }
          switch (payload.type) {
            case "enter":
            case "over": {
              setIsDragging(true);
              setActiveZoneId(resolveZoneId(payload.position));
              break;
            }
            case "drop": {
              const zoneId = resolveZoneId(payload.position);
              if (zoneId != null) {
                zonesRef.current.get(zoneId)?.onDrop(payload.paths);
              }
              setIsDragging(false);
              setActiveZoneId(null);
              break;
            }
            default: {
              setIsDragging(false);
              setActiveZoneId(null);
            }
          }
        })
        .then((dispose) => {
          if (isMounted) {
            unlisten = dispose;
          } else {
            dispose();
          }
        })
        .catch((error) => {
          console.error("[file-drop] failed to attach drag-drop listener", error);
        });
    } catch (error) {
      console.error("[file-drop] getCurrentWebview() threw", error);
    }

    return () => {
      isMounted = false;
      unlisten?.();
    };
  }, [resolveZoneId]);

  const register = useCallback((zone: DropZone) => {
    zonesRef.current.set(zone.id, zone);
    return () => {
      zonesRef.current.delete(zone.id);
    };
  }, []);

  const value = useMemo(
    () => ({ register, isDragging, activeZoneId }),
    [register, isDragging, activeZoneId],
  );

  return (
    <DragDropContext.Provider value={value}>
      {children}
    </DragDropContext.Provider>
  );
}

/**
 * Registers `ref` as a window-level drop target. Returns whether a drag is in
 * progress and whether the cursor is currently over this zone.
 */
// eslint-disable-next-line react-refresh/only-export-components
export function useDropZone(
  ref: RefObject<HTMLElement | null>,
  onDrop: (paths: string[]) => void,
) {
  const context = useContext(DragDropContext);
  const zoneId = `drop-zone-${useId()}`;

  const onDropRef = useRef(onDrop);
  useEffect(() => {
    onDropRef.current = onDrop;
  }, [onDrop]);

  // `register` is referentially stable, so this effect runs once per mount —
  // depending on the whole `context` would re-register on every drag update.
  const register = context?.register;
  useEffect(() => {
    if (register == null) {
      return;
    }

    return register({
      id: zoneId,
      ref,
      onDrop: (paths) => onDropRef.current(paths),
    });
  }, [register, ref, zoneId]);

  return {
    isDragging: context?.isDragging ?? false,
    isActive: context?.activeZoneId === zoneId,
  };
}

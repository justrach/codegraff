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
import {
  dataTransferHasAttachmentPayload,
  extractAttachmentTransferItems,
  type AttachmentTransferItem,
} from "@/components/attachments/attachmentTransfer";
import { resolveDropZoneCandidateId } from "./fileDropResolution";

interface DropZone {
  id: string;
  ref: RefObject<HTMLElement | null>;
  onDrop: (items: AttachmentTransferItem[]) => void;
  isActiveTarget: () => boolean;
}

interface DropZoneOptions {
  isActiveTarget?: boolean;
}

interface DragDropContextValue {
  register: (zone: DropZone) => () => void;
  isDragging: boolean;
  activeZoneId: string | null;
}

const DragDropContext = createContext<DragDropContextValue | null>(null);

export function DragDropProvider({ children }: { children: ReactNode }) {
  const zonesRef = useRef<Map<string, DropZone>>(new Map());
  const dragDepthRef = useRef(0);
  const [isDragging, setIsDragging] = useState(false);
  const [activeZoneId, setActiveZoneId] = useState<string | null>(null);

  const resolveZoneId = useCallback(
    (position: {
      x: number;
      y: number;
      cssPixels?: boolean;
    }): string | null => {
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

      // Multiple panes visible: hit-test the cursor. Native bridges may report
      // physical pixels; DOM drag events report CSS pixels.
      const dpr = window.devicePixelRatio || 1;
      const x = position.cssPixels ? position.x : position.x / dpr;
      const y = position.cssPixels ? position.y : position.y / dpr;

      return resolveDropZoneCandidateId(
        candidates.flatMap((zone) => {
          const element = zone.ref.current;
          if (element == null) {
            return [];
          }
          return [
            {
              id: zone.id,
              rect: element.getBoundingClientRect(),
              isActiveTarget: zone.isActiveTarget(),
            },
          ];
        }),
        { x, y },
      );
    },
    [],
  );

  useEffect(() => {
    function clearDragState() {
      dragDepthRef.current = 0;
      setIsDragging(false);
      setActiveZoneId(null);
    }

    function resolveDomZoneId(event: DragEvent) {
      return resolveZoneId({
        x: event.clientX,
        y: event.clientY,
        cssPixels: true,
      });
    }

    function handleDragEnter(event: DragEvent) {
      if (!dataTransferHasAttachmentPayload(event.dataTransfer)) {
        return;
      }
      event.preventDefault();
      dragDepthRef.current += 1;
      setIsDragging(true);
      setActiveZoneId(resolveDomZoneId(event));
    }

    function handleDragOver(event: DragEvent) {
      if (!dataTransferHasAttachmentPayload(event.dataTransfer)) {
        return;
      }
      event.preventDefault();
      if (event.dataTransfer != null) {
        event.dataTransfer.dropEffect = "copy";
      }
      setIsDragging(true);
      setActiveZoneId(resolveDomZoneId(event));
    }

    function handleDragLeave(event: DragEvent) {
      if (!dataTransferHasAttachmentPayload(event.dataTransfer)) {
        return;
      }
      dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
      if (
        dragDepthRef.current === 0 ||
        event.clientX <= 0 ||
        event.clientY <= 0 ||
        event.clientX >= window.innerWidth ||
        event.clientY >= window.innerHeight
      ) {
        clearDragState();
      }
    }

    function handleDrop(event: DragEvent) {
      if (!dataTransferHasAttachmentPayload(event.dataTransfer)) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();

      const zoneId = resolveDomZoneId(event);
      const items = extractAttachmentTransferItems(event.dataTransfer);
      if (zoneId != null && items.length > 0) {
        zonesRef.current.get(zoneId)?.onDrop(items);
      }
      clearDragState();
    }

    const listenerOptions = { capture: true };
    document.addEventListener("dragenter", handleDragEnter, listenerOptions);
    document.addEventListener("dragover", handleDragOver, listenerOptions);
    document.addEventListener("dragleave", handleDragLeave, listenerOptions);
    document.addEventListener("drop", handleDrop, listenerOptions);
    window.addEventListener("blur", clearDragState);
    window.addEventListener("dragend", clearDragState);

    return () => {
      document.removeEventListener(
        "dragenter",
        handleDragEnter,
        listenerOptions,
      );
      document.removeEventListener(
        "dragover",
        handleDragOver,
        listenerOptions,
      );
      document.removeEventListener(
        "dragleave",
        handleDragLeave,
        listenerOptions,
      );
      document.removeEventListener("drop", handleDrop, listenerOptions);
      window.removeEventListener("blur", clearDragState);
      window.removeEventListener("dragend", clearDragState);
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
  onDrop: (items: AttachmentTransferItem[]) => void,
  options: DropZoneOptions = {},
) {
  const context = useContext(DragDropContext);
  const zoneId = `drop-zone-${useId()}`;

  const onDropRef = useRef(onDrop);
  useEffect(() => {
    onDropRef.current = onDrop;
  }, [onDrop]);
  const isActiveTargetRef = useRef(options.isActiveTarget ?? false);
  useEffect(() => {
    isActiveTargetRef.current = options.isActiveTarget ?? false;
  }, [options.isActiveTarget]);

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
      isActiveTarget: () => isActiveTargetRef.current,
    });
  }, [register, ref, zoneId]);

  return {
    isDragging: context?.isDragging ?? false,
    isActive: context?.activeZoneId === zoneId,
  };
}

import { create } from "zustand";

import type { ChatBinding } from "@/services/desktop/types/contracts";

interface ArtifactsDrawerState {
  openByKey: Record<string, boolean>;
  toggle: (key: string) => void;
  setOpen: (key: string, open: boolean) => void;
}

const useArtifactsDrawerStore = create<ArtifactsDrawerState>((set) => ({
  openByKey: {},
  toggle: (key) =>
    set((state) => ({
      openByKey: { ...state.openByKey, [key]: !state.openByKey[key] },
    })),
  setOpen: (key, open) =>
    set((state) => ({
      openByKey: { ...state.openByKey, [key]: open },
    })),
}));

function keyFor(binding?: ChatBinding | null): string {
  return binding == null
    ? "__global__"
    : `${binding.workspacePath}::${binding.conversationId}`;
}

/**
 * Per-conversation artifacts drawer open-state, shared between the standard
 * panel header and the dockview tab header (which live in separate subtrees).
 */
export function useArtifactsDrawer(binding?: ChatBinding | null) {
  const key = keyFor(binding);
  const isOpen = useArtifactsDrawerStore((state) => state.openByKey[key] ?? false);
  const toggle = useArtifactsDrawerStore((state) => state.toggle);
  const setOpen = useArtifactsDrawerStore((state) => state.setOpen);

  return {
    isOpen,
    toggle: () => toggle(key),
    close: () => setOpen(key, false),
  };
}

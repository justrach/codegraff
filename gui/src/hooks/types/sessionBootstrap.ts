import type { SessionSnapshot } from "@/services/desktop/types/contracts";

export interface UseSessionBootstrapOptions {
  setSessionSnapshot: (snapshot: SessionSnapshot) => void;
  onReady?: () => void;
}

import type { SessionSnapshot } from "@/services/desktop/types/contracts";

export interface UseSessionBootstrapOptions {
  setSessionSnapshot: (snapshot: SessionSnapshot) => void;
  onReady?: () => void;
  /**
   * Polling keeps file-backed CLI sessions visible in the GUI while the app is
   * already open. The Zig backend imports *.session.json files during snapshot
   * reads; set to 0 to disable in tests.
   */
  cliSessionSyncIntervalMs?: number;
}

import { desktop } from './desktop';
import { loadWorkspaces, loadActiveWorkspace, saveWorkspaces, saveActiveWorkspace, type Workspace } from './workspaces';
export async function restoreProjects(storage: Storage) {
  try {
    const saved = await desktop()?.projects?.('load');
    if (saved) { saveWorkspaces(storage, saved.list); saveActiveWorkspace(storage, saved.active); return saved; }
  } catch { /* Older desktops and damaged settings can still recover browser preferences. */ }
  return { list: loadWorkspaces(storage), active: loadActiveWorkspace(storage) };
}
export function persistProjects(storage: Storage, list: Workspace[], active: string | null) {
  saveWorkspaces(storage, list); saveActiveWorkspace(storage, active);
  void desktop()?.projects?.('save', { list, active }).catch(() => {
    // The browser copy remains available if the settings volume is unavailable.
  });
}

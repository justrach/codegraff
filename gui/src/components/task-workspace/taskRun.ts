const STORAGE_KEY = "graff.task-run";
export const TASK_RUN_EVENT = "graff:task-run";

export function queueTaskRun(workspacePath: string, command: string) {
  sessionStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({ workspacePath, command }),
  );
  window.dispatchEvent(new Event(TASK_RUN_EVENT));
}

export function takeTaskRun(
  workspacePath: string,
): { workspacePath: string; command: string } | null {
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (raw == null) {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as {
      workspacePath?: string;
      command?: string;
    };
    if (parsed.workspacePath !== workspacePath || !parsed.command) {
      return null;
    }
    sessionStorage.removeItem(STORAGE_KEY);
    return { workspacePath, command: parsed.command };
  } catch {
    sessionStorage.removeItem(STORAGE_KEY);
    return null;
  }
}

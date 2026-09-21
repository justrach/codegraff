async function post(action: string, root: string | undefined, name?: string) {
  const response = await fetch("/api/worktree", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action, root, name }),
  });
  const body = await response.json() as { error?: string; path?: string; command?: string; output?: string; root?: string; bytes?: number };
  if (!response.ok) throw new Error(body.error || "Worktree request failed");
  return body;
}

export async function createTaskWorkspace(root?: string): Promise<string | null> {
  const typed = window.prompt("New task workspace name");
  if (typed == null) return null;
  const created = await post("create", root, typed);
  if (created.path) window.dispatchEvent(new CustomEvent("graff-open-workspace", { detail: { cwd: created.path } }));
  return created.path ?? null;
}

export async function runTaskWorkspace(root: string | undefined, showTerminal: () => void): Promise<void> {
  const body = await post("run", root);
  if (body.command) {
    sessionStorage.setItem("graff.terminal.command", body.command);
    showTerminal();
    window.dispatchEvent(new CustomEvent("graff-terminal-command", { detail: { command: body.command } }));
  }
}

export async function archiveTaskWorkspace(root?: string): Promise<void> {
  if (!window.confirm("Archive this task workspace? Dirty or unique-commit trees stay.")) return;
  const body = await post("archive", root);
  if (body.output && !body.output.startsWith("✓")) window.alert(body.output);
  if (body.root) window.dispatchEvent(new CustomEvent("graff-open-workspace", { detail: { cwd: body.root } }));
}

export async function updateTaskWorkspace(root?: string): Promise<void> {
  const body = await post("update", root);
  if (body.output) window.alert(body.output);
}

export async function workspaceBytes(root?: string): Promise<number> {
  const body = await post("status", root);
  return typeof body.bytes === "number" ? body.bytes : 0;
}

export async function landTaskWorkspace(root?: string): Promise<void> {
  if (!window.confirm("Land this workspace onto the base branch as one commit and remove the checkout?")) return;
  const body = await post("merge", root);
  if (body.output) window.alert(body.output);
  if (body.root) window.dispatchEvent(new CustomEvent("graff-open-workspace", { detail: { cwd: body.root } }));
}

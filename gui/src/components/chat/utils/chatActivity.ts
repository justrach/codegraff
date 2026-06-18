import type { ActivityOperation } from "../types/chatThread";
import { classifyUnknownToolName } from "./classifyActivityResult";

// Turn a raw tool name like "webfetch" / "web_fetch" into a readable verb
// phrase, e.g. "Fetched web content".
function formatUnknownToolLabel(name: string): string {
  switch (classifyUnknownToolName(name)) {
    case "web":
      return "Fetched web content";
    case "github":
      return `Ran ${name} on GitHub`;
    default:
      return `Ran ${name}`;
  }
}

function formatPath(path: string, workspacePath: string | null): string {
  if (workspacePath == null || path.startsWith(workspacePath) === false) {
    return path;
  }

  const trimmed = path.slice(workspacePath.length).replace(/^\/+/, "");
  return trimmed.length === 0 ? "." : trimmed;
}

export function formatOperationLabel(
  operation: ActivityOperation,
  workspacePath: string | null,
): string {
  switch (operation.detail.kind) {
    case "file_read":
      return `Read ${formatPath(operation.detail.path, workspacePath)}`;
    case "file_update": {
      const verb = (() => {
        switch (operation.detail.operation) {
          case "create":
            return "Created";
          case "overwrite":
            return "Overwrote";
          case "replace":
            return "Updated";
          case "remove":
            return "Removed";
          case "undo":
            return "Undid";
          default:
            return "Updated";
        }
      })();

      return `${verb} ${formatPath(operation.detail.path, workspacePath)}`;
    }
    case "shell":
      return operation.detail.command;
    case "search":
      return `Searched ${operation.detail.path ? formatPath(operation.detail.path, workspacePath) : "."} for ${operation.detail.pattern}`;
    case "codebase_search":
      return `Codebase search: ${operation.detail.queries.join(" · ")}`;
    case "fetch":
      return `Fetched ${operation.detail.url}`;
    case "followup":
      return `Asked follow-up: ${operation.detail.question}`;
    case "plan":
      return `Updated plan ${operation.detail.planName}`;
    case "skill":
      return `Loaded skill ${operation.detail.name}`;
    case "task":
      return operation.detail.agentId
        ? `${operation.detail.agentId} · ${operation.detail.label}`
        : `Subagent · ${operation.detail.label}`;
    case "todo_read":
      return "Read todos";
    case "todo_write":
      return `Updated ${operation.detail.count} todo item${operation.detail.count === 1 ? "" : "s"}`;
    case "unknown":
      return formatUnknownToolLabel(operation.detail.name);
    default:
      return operation.name;
  }
}

import type { CommandDescriptor } from "@/services/desktop/types/contracts";

export function getCommandExecutionLabel(command: CommandDescriptor): string {
  switch (command.executionKind) {
    case "runnable":
      return "Run";
    case "modal":
      return "Open";
    case "terminalAssisted":
      return "Terminal";
    case "unavailable":
      return "Unavailable";
  }
}

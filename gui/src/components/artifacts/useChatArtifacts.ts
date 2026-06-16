import { useMemo } from "react";

import type { TranscriptMessage } from "@/services/desktop/types/contracts";
import { basename } from "@/components/attachments/attachmentTypes";

export interface ChatArtifact {
  path: string;
  name: string;
  ext: string;
}

function extensionOf(name: string): string {
  const dotIndex = name.lastIndexOf(".");
  if (dotIndex <= 0 || dotIndex === name.length - 1) {
    return "";
  }
  return name.slice(dotIndex + 1).toLowerCase();
}

function pathFromMessage(message: TranscriptMessage): string | null {
  if (message.kind === "tool_start" && message.detail.kind === "file_update") {
    return message.detail.path;
  }
  if (
    message.kind === "tool_end" &&
    message.detail != null &&
    message.detail.kind === "file_diff"
  ) {
    return message.detail.path;
  }
  return null;
}

/**
 * Derives the files the agent wrote/modified in this chat from the message
 * stream (read-only — no harness change). Deduped by path, most recently
 * touched first.
 */
export function useChatArtifacts(messages: TranscriptMessage[]): ChatArtifact[] {
  return useMemo(() => {
    if (import.meta.env.DEV) {
      console.debug(
        "[artifacts] message kinds",
        messages.map((message) =>
          message.kind === "tool_start" || message.kind === "tool_end"
            ? `${message.kind}:${message.name}:${
                message.kind === "tool_start"
                  ? message.detail.kind
                  : (message.detail?.kind ?? "null")
              }`
            : message.kind,
        ),
      );
    }

    const byPath = new Map<string, ChatArtifact>();

    for (const message of messages) {
      const path = pathFromMessage(message);
      if (path == null) {
        continue;
      }

      const name = basename(path);
      // Re-insert so the most recently touched path moves to the end.
      byPath.delete(path);
      byPath.set(path, { path, name, ext: extensionOf(name) });
    }

    return Array.from(byPath.values()).reverse();
  }, [messages]);
}

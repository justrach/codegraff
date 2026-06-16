import { useCallback, useEffect, useMemo, useState } from "react";

import * as desktopClient from "@/services/desktop/client";
import type { CommandDescriptor } from "@/services/desktop/types/contracts";

/** Matches a slash-command being typed at the very start of the draft. */
const SLASH_QUERY = /^\/([\w-]*)$/;

const MAX_VISIBLE = 8;

export interface CommandAutocompleteState {
  isOpen: boolean;
  items: CommandDescriptor[];
  activeIndex: number;
  query: string;
  setActiveIndex: (index: number) => void;
  /** Run the highlighted command (routes/executes it). */
  pick: (index?: number) => void;
  /** Insert `/<name> ` into the draft so the user can append arguments. */
  complete: (index?: number) => void;
  /**
   * Keyboard handler for the textarea. Returns true when the event was
   * consumed by the menu (caller should not run its own handling).
   */
  handleKeyDown: (event: React.KeyboardEvent<HTMLTextAreaElement>) => boolean;
}

interface Options {
  promptDraft: string;
  setPromptDraft: (value: string) => void;
  workspacePath?: string | null;
  enabled: boolean;
  onSelect: (command: CommandDescriptor) => void;
}

function matches(command: CommandDescriptor, query: string): boolean {
  const needle = query.toLowerCase();
  if (needle.length === 0) {
    return true;
  }
  if (command.name.toLowerCase().startsWith(needle)) {
    return true;
  }
  return command.aliases.some((alias) =>
    alias.toLowerCase().startsWith(needle),
  );
}

export function commandMatchesExactQuery(
  command: Pick<CommandDescriptor, "name" | "aliases">,
  query: string,
): boolean {
  const needle = query.toLowerCase();
  if (command.name.toLowerCase() === needle) {
    return true;
  }

  return command.aliases.some((alias) => alias.toLowerCase() === needle);
}

function rank(command: CommandDescriptor, query: string): number {
  const needle = query.toLowerCase();
  if (commandMatchesExactQuery(command, needle)) {
    return 0;
  }
  if (command.name.toLowerCase().startsWith(needle)) {
    return 1;
  }
  return 2;
}

export function useCommandAutocomplete({
  promptDraft,
  setPromptDraft,
  workspacePath,
  enabled,
  onSelect,
}: Options): CommandAutocompleteState {
  const [commands, setCommands] = useState<CommandDescriptor[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);
  // Query the user dismissed with Escape; the menu stays closed until the
  // draft (and therefore the query) changes again.
  const [dismissedQuery, setDismissedQuery] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    desktopClient
      .listCommands(workspacePath ?? null)
      .then((result) => {
        if (!cancelled) {
          setCommands(result);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setCommands([]);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [workspacePath]);

  const slashMatch = SLASH_QUERY.exec(promptDraft);
  const query = slashMatch?.[1] ?? null;

  const items = useMemo(() => {
    if (query == null) {
      return [];
    }
    return commands
      .filter((command) => matches(command, query))
      .sort((a, b) => {
        const byRank = rank(a, query) - rank(b, query);
        return byRank !== 0 ? byRank : a.name.localeCompare(b.name);
      })
      .slice(0, MAX_VISIBLE);
  }, [commands, query]);

  // Reset the highlight whenever the query changes (adjust state during render
  // rather than in an effect — the React-recommended pattern).
  const [lastQuery, setLastQuery] = useState(query);
  if (query !== lastQuery) {
    setLastQuery(query);
    setActiveIndex(0);
  }

  const safeIndex = activeIndex < items.length ? activeIndex : 0;
  const hasExactCommandMatch =
    query != null &&
    items.some((command) => commandMatchesExactQuery(command, query));

  const isOpen =
    enabled && query != null && items.length > 0 && dismissedQuery !== query;

  const pick = useCallback(
    (index?: number) => {
      const target = items[index ?? safeIndex];
      if (target != null) {
        onSelect(target);
      }
    },
    [items, safeIndex, onSelect],
  );

  const complete = useCallback(
    (index?: number) => {
      const target = items[index ?? safeIndex];
      if (target != null) {
        setPromptDraft(`/${target.name} `);
      }
    },
    [items, safeIndex, setPromptDraft],
  );

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLTextAreaElement>): boolean => {
      if (!isOpen) {
        return false;
      }
      switch (event.key) {
        case "ArrowDown":
          event.preventDefault();
          setActiveIndex((current) =>
            current + 1 >= items.length ? 0 : current + 1,
          );
          return true;
        case "ArrowUp":
          event.preventDefault();
          setActiveIndex((current) =>
            current - 1 < 0 ? items.length - 1 : current - 1,
          );
          return true;
        case "Enter":
          // Plain Enter autofills partial commands, but exact commands should
          // fall through to the composer submit path so `/help` runs directly.
          if (event.metaKey || event.ctrlKey || hasExactCommandMatch) {
            return false;
          }
          event.preventDefault();
          complete();
          return true;
        case "Tab":
          event.preventDefault();
          complete();
          return true;
        case "Escape":
          event.preventDefault();
          setDismissedQuery(query);
          return true;
        default:
          return false;
      }
    },
    [isOpen, items.length, complete, query, hasExactCommandMatch],
  );

  return {
    isOpen,
    items,
    activeIndex: safeIndex,
    query: query ?? "",
    setActiveIndex,
    pick,
    complete,
    handleKeyDown,
  };
}

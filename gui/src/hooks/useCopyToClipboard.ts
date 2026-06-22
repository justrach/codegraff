import { useCallback, useEffect, useRef, useState } from "react";

import { writeClipboardText } from "@/services/desktop/client";
import type { UseCopyToClipboardOptions } from "./types/copy";

const DEFAULT_COPY_RESET_DELAY_MS = 1200;

export function useCopyToClipboard(
  options: UseCopyToClipboardOptions = {},
) {
  const { resetDelayMs = DEFAULT_COPY_RESET_DELAY_MS } = options;
  const [copied, setCopied] = useState(false);
  const resetCopyTimeoutRef = useRef<number | null>(null);

  const clearResetTimeout = useCallback(() => {
    if (resetCopyTimeoutRef.current == null) {
      return;
    }

    window.clearTimeout(resetCopyTimeoutRef.current);
    resetCopyTimeoutRef.current = null;
  }, []);

  const copy = useCallback(
    async (value: string | null | undefined): Promise<boolean> => {
      if (value == null || value.length === 0) {
        return false;
      }

      try {
        await writeClipboardText(value);
        setCopied(true);
        clearResetTimeout();
        resetCopyTimeoutRef.current = window.setTimeout(() => {
          setCopied(false);
          resetCopyTimeoutRef.current = null;
        }, resetDelayMs);
        return true;
      } catch {
        setCopied(false);
        clearResetTimeout();
        return false;
      }
    },
    [clearResetTimeout, resetDelayMs],
  );

  useEffect(() => {
    return () => {
      clearResetTimeout();
    };
  }, [clearResetTimeout]);

  return {
    copied,
    copy,
  };
}

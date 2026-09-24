import { useEffect, useState } from "react";
import { loadHistory } from "@/lib/prompt-history";

export function usePromptRecall() {
  const [history, setHistory] = useState<string[]>([]);
  useEffect(() => { setHistory(loadHistory(window.localStorage)); }, []);
  return [history, setHistory] as const;
}

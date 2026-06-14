import { createContext } from "react";

import type { SessionActionsContextValue } from "./types/sessionContext";

export const SessionActionsContext =
  createContext<SessionActionsContextValue | null>(null);

import * as React from "react";

import {
  DEFAULT_APP_TARGET_ID,
  OPEN_IN_PREFERRED_APP_STORAGE_KEY,
} from "../constants/conversationHeader";
import { isAppTargetId } from "../utils/conversationHeader";
import type { AppTarget, AppTargetId } from "../types/conversationHeader";

export function usePreferredOpenTarget(openTargets: ReadonlyArray<AppTarget>) {
  const [preferredAppId, setPreferredAppId] = React.useState<AppTargetId>(
    DEFAULT_APP_TARGET_ID,
  );
  const hasInitializedPreferredAppRef = React.useRef(false);
  const openTargetsKey = openTargets.map((target) => target.id).join("|");
  const resolvedPreferredAppId =
    openTargets.length > 0 &&
    openTargets.some((target) => target.id === preferredAppId)
      ? preferredAppId
      : (openTargets[0]?.id ?? preferredAppId);

  React.useEffect(() => {
    if (hasInitializedPreferredAppRef.current || openTargets.length === 0) {
      return;
    }

    const storedPreferredAppId = window.localStorage.getItem(
      OPEN_IN_PREFERRED_APP_STORAGE_KEY,
    );
    const nextPreferredAppId =
      storedPreferredAppId != null &&
      isAppTargetId(storedPreferredAppId) &&
      openTargets.some((target) => target.id === storedPreferredAppId)
        ? storedPreferredAppId
        : openTargets[0].id;

    hasInitializedPreferredAppRef.current = true;
    setPreferredAppId(nextPreferredAppId);
  }, [openTargets, openTargetsKey]);

  React.useEffect(() => {
    if (openTargets.length === 0) {
      return;
    }

    window.localStorage.setItem(
      OPEN_IN_PREFERRED_APP_STORAGE_KEY,
      resolvedPreferredAppId,
    );
  }, [openTargets.length, resolvedPreferredAppId]);

  return {
    resolvedPreferredAppId,
    setPreferredAppId,
  };
}

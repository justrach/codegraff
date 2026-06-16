import { useEffect, useState } from "react";

import { EXPANDED_PROJECTS_STORAGE_KEY } from "@/components/constants/projectSidebar";

function loadExpandedProjectPaths() {
  if (typeof window === "undefined") {
    return [];
  }

  try {
    const storedValue = window.localStorage.getItem(
      EXPANDED_PROJECTS_STORAGE_KEY,
    );
    if (storedValue == null) {
      return [];
    }

    const parsedValue: unknown = JSON.parse(storedValue);
    return Array.isArray(parsedValue)
      ? parsedValue.filter(
          (value): value is string => typeof value === "string",
        )
      : [];
  } catch {
    return [];
  }
}

export function useExpandedProjectPaths() {
  const [expandedProjectPaths, setExpandedProjectPaths] = useState<string[]>(
    () => loadExpandedProjectPaths(),
  );

  useEffect(() => {
    window.localStorage.setItem(
      EXPANDED_PROJECTS_STORAGE_KEY,
      JSON.stringify(expandedProjectPaths),
    );
  }, [expandedProjectPaths]);

  function isProjectExpanded(workspacePath: string) {
    return expandedProjectPaths.includes(workspacePath);
  }

  function toggleProjectExpanded(workspacePath: string) {
    setExpandedProjectPaths((current) =>
      current.includes(workspacePath)
        ? current.filter((path) => path !== workspacePath)
        : [...current, workspacePath],
    );
  }

  function ensureProjectExpanded(workspacePath: string) {
    setExpandedProjectPaths((current) =>
      current.includes(workspacePath) ? current : [...current, workspacePath],
    );
  }

  function collapseProject(workspacePath: string) {
    setExpandedProjectPaths((current) =>
      current.filter((path) => path !== workspacePath),
    );
  }

  return {
    collapseProject,
    ensureProjectExpanded,
    isProjectExpanded,
    toggleProjectExpanded,
  };
}

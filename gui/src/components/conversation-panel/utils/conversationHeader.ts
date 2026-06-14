import { appTargets } from "../constants/conversationHeader";
import type { AppTargetId } from "../types/conversationHeader";

export function isAppTargetId(value: string): value is AppTargetId {
  return appTargets.some((target) => target.id === value);
}

export function normalizeSearchText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function rankSearchFieldMatch(field: string, normalizedQuery: string): number {
  const normalizedField = normalizeSearchText(field);
  if (
    normalizedField.length === 0 ||
    !normalizedField.includes(normalizedQuery)
  ) {
    return Number.NEGATIVE_INFINITY;
  }

  if (normalizedField === normalizedQuery) {
    return 3;
  }

  if (normalizedField.startsWith(normalizedQuery)) {
    return 2;
  }

  return 1;
}

export function rankBranchMatch(
  branchName: string,
  normalizedQuery: string,
): number {
  const searchTerms = [
    branchName,
    branchName.replace(/^origin\//, ""),
    ...branchName.split("/"),
  ].filter((term) => term.length > 0);

  for (const [index, field] of searchTerms.entries()) {
    const fieldRank = rankSearchFieldMatch(field, normalizedQuery);
    if (fieldRank !== Number.NEGATIVE_INFINITY) {
      return 1_000 - index * 100 + fieldRank;
    }
  }

  return Number.NEGATIVE_INFINITY;
}

interface DropZoneRect {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

interface DropZoneCandidate {
  id: string;
  rect: DropZoneRect;
  isActiveTarget: boolean;
}

export function resolveDropZoneCandidateId(
  candidates: DropZoneCandidate[],
  position: { x: number; y: number },
): string | null {
  for (const zone of candidates) {
    const rect = zone.rect;
    if (
      position.x >= rect.left &&
      position.x <= rect.right &&
      position.y >= rect.top &&
      position.y <= rect.bottom
    ) {
      return zone.id;
    }
  }

  const activeCandidates = candidates.filter((zone) => zone.isActiveTarget);
  if (activeCandidates.length === 1) {
    return activeCandidates[0].id;
  }

  if (candidates.length === 1) {
    return candidates[0].id;
  }

  return null;
}

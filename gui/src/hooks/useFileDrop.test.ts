import { describe, expect, test } from "bun:test";

import { resolveDropZoneCandidateId } from "./fileDropResolution";

function zone(
  id: string,
  left: number,
  top: number,
  isActiveTarget = false,
) {
  return {
    id,
    isActiveTarget,
    rect: {
      left,
      right: left + 100,
      top,
      bottom: top + 100,
    },
  };
}

describe("resolveDropZoneCandidateId", () => {
  test("uses exact hit testing before the active fallback", () => {
    expect(
      resolveDropZoneCandidateId(
        [zone("inactive", 0, 0), zone("active", 200, 0, true)],
        { x: 50, y: 50 },
      ),
    ).toBe("inactive");
  });

  test("routes broad drops to the active visible composer", () => {
    expect(
      resolveDropZoneCandidateId(
        [zone("left", 0, 0), zone("right", 200, 0, true)],
        { x: 150, y: 50 },
      ),
    ).toBe("right");
  });

  test("routes to the only visible composer without relying on coordinates", () => {
    expect(resolveDropZoneCandidateId([zone("only", 0, 0)], { x: 999, y: 999 }))
      .toBe("only");
  });

  test("does not guess when multiple visible composers are equally active", () => {
    expect(
      resolveDropZoneCandidateId(
        [zone("left", 0, 0, true), zone("right", 200, 0, true)],
        { x: 150, y: 50 },
      ),
    ).toBeNull();
  });
});

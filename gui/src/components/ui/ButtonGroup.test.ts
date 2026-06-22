import { describe, expect, test } from "bun:test";

import { buttonGroupVariants } from "./ButtonGroup";

// Regression guard for #74: a segmented group previously deleted adjacent
// buttons' shared edge (border-l-0 / border-t-0), so those sides vanished. The
// fix overlaps the seam with a negative margin so every button keeps all four
// borders.
describe("buttonGroupVariants segmented borders (#74)", () => {
  test("horizontal overlaps the shared edge instead of deleting the left border", () => {
    const cls = buttonGroupVariants({ orientation: "horizontal" });
    expect(cls).not.toContain("border-l-0");
    expect(cls).toContain("-ml-px");
    // active/hover button border draws on top of the 1px overlap
    expect(cls).toContain("*:data-slot:relative");
    expect(cls).toContain("*:hover:z-10");
  });

  test("vertical overlaps the shared edge instead of deleting the top border", () => {
    const cls = buttonGroupVariants({ orientation: "vertical" });
    expect(cls).not.toContain("border-t-0");
    expect(cls).toContain("-mt-px");
  });

  test("defaults to the horizontal segmented layout", () => {
    expect(buttonGroupVariants({})).toContain("-ml-px");
  });
});

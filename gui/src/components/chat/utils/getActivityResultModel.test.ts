import { describe, expect, test } from "bun:test";

import type { ActivityOperation } from "../types/chatThread";
import { getActivityResultModel } from "./getActivityResultModel";

function createFileUpdateOperation(
  overrides: Partial<ActivityOperation> = {},
): ActivityOperation {
  return {
    id: "tool-end-1",
    requestId: "req-1",
    name: "write",
    callId: "call-1",
    detail: {
      kind: "file_update",
      path: "src/example.ts",
      operation: "replace",
    },
    completed: true,
    isError: false,
    ...overrides,
  };
}

describe("getActivityResultModel", () => {
  test("returns file diffs for file updates even when the result detail is plain text", () => {
    const result = getActivityResultModel(
      createFileUpdateOperation({
        resultDetail: {
          kind: "text",
          text: ["1 1 | const before = true;", "2   |-removed();", "  2 |+added();"].join(
            "\n",
          ),
        },
      }),
    );

    expect(result).not.toBeNull();
    expect(result?.kind).toBe("file_diff");
    if (result?.kind !== "file_diff") {
      return;
    }

    expect(result.path).toBe("src/example.ts");
    expect(result.patch).toContain("diff --git a/src/example.ts b/src/example.ts");
    expect(result.patch).toContain("-removed();");
    expect(result.patch).toContain("+added();");
  });
});

import assert from "node:assert/strict";
import test from "node:test";
import { hostOpenCommand } from "./host-open.ts";

test("open and reveal use the host file manager", () => {
  assert.deepEqual(hostOpenCommand("open", "/src/app.ts", "darwin"), { bin: "open", args: ["/src/app.ts"] });
  assert.deepEqual(hostOpenCommand("reveal", "/src/app.ts", "darwin"), { bin: "open", args: ["-R", "/src/app.ts"] });
  assert.deepEqual(hostOpenCommand("open", "/src/app.ts", "linux"), { bin: "xdg-open", args: ["/src/app.ts"] });
  assert.deepEqual(hostOpenCommand("reveal", "/src/app.ts", "linux"), { bin: "xdg-open", args: ["/src"] });
  assert.equal(hostOpenCommand("open", "C:\\src\\app.ts", "win32"), null);
  assert.equal(hostOpenCommand("rename", "/src/app.ts", "linux"), null);
});

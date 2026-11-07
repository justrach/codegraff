import { bindings, defineConfig, exports as configExports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// Local live-test bridge holds the real key in a Node process, not build output.
const bridge = process.env.GRAFF_SANDBOX_TEST_BRIDGE ?? "";
if (bridge && !/^http:\/\/127\.0\.0\.1:\d+$/.test(bridge)) throw new Error("Test bridge must be loopback");
const workerName = "graff-workers-sandbox-example";
export default defineConfig({
  worker: {
    name: workerName,
    compatibilityDate: "2026-10-06",
    entrypoint,
    exports: { SandboxTask: configExports.durableObject({ storage: "sqlite" }) },
    env: {
      TASKS: bindings.durableObject({ worker: workerName, exportName: "SandboxTask" }),
      CODEGRAFF_API_KEY: bindings.secret(),
      INGRESS_TOKEN: bindings.secret(),
      MODEL_NAME: bindings.text(process.env.GRAFF_SANDBOX_TEST_MODEL ?? "ultramarine-1-flash"),
      TEST_BRIDGE: bindings.text(bridge),
    },
  },
});

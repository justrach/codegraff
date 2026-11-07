import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
  worker: {
    name: "graff-workers-engine-example",
    compatibilityDate: "2026-10-06",
    entrypoint,
    env: {
      MODE: bindings.text("mock"),
      MODEL_ENDPOINT: bindings.text(""),
      MODEL_NAME: bindings.text(""),
      // Required only for MODE=real. Supply secrets through cf, never source.
      MODEL_TOKEN: bindings.secret(),
      INGRESS_TOKEN: bindings.secret(),
    },
  },
});

import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./e2e", testMatch: "queue.pw.ts", workers: 1,
  use: { baseURL: "http://127.0.0.1:3021", headless: true },
  webServer: {
    command: "GRAFF_VISUAL_TESTS=1 GRAFF_DESKTOP_TOKEN= bunx next dev --port 3021 --hostname 127.0.0.1",
    url: "http://127.0.0.1:3021", timeout: 120000, reuseExistingServer: false,
  },
  reporter: "list",
});

import {defineConfig} from "@playwright/test";
// GRAFF_DESKTOP_TOKEN is cleared for the same reason the Electron visual
// harnesses clear it: proxy.ts gates /api/* on the token the desktop renderer
// receives, and a spec drives those routes without it.
export default defineConfig({testDir:"./e2e",testMatch:"views.pw.ts",workers:1,use:{channel:"chrome",baseURL:"http://localhost:3018",headless:true},webServer:{command:"GRAFF_VISUAL_TESTS=1 GRAFF_DESKTOP_TOKEN= bunx next dev --port 3018",url:"http://localhost:3018",timeout:120000,reuseExistingServer:false},reporter:"list"});

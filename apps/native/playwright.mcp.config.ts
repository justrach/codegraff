import {defineConfig} from "@playwright/test";
export default defineConfig({testDir:"./e2e",testMatch:"mcp-apps.pw.ts",workers:1,use:{channel:"chrome",baseURL:"http://localhost:3017",headless:true},webServer:{command:"GRAFF_VISUAL_TESTS=1 bunx next dev --port 3017",url:"http://localhost:3017",timeout:120000,reuseExistingServer:false},reporter:"list"});

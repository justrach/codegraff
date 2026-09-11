import {test,expect} from "bun:test";
import {mkdtemp,writeFile,symlink,rm} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {mcpAppId,validAppId} from "./mcp-apps";
import {readMcpApp} from "./mcp-app-store";
import {applyAcpUpdate,emptyTurn} from "./acp";
const id="a".repeat(32);
test("only opaque local app ids are recognized",()=>{
  expect(mcpAppId(`[MCP app](/home/test/.graff/mcp-apps/${id}.html)`)).toBe(id);
  expect(mcpAppId(`[MCP app](https://evil/${id}.html)`)).toBeUndefined();
  for(const bad of ['../secret','a'.repeat(31),'A'.repeat(32),'a'.repeat(33)])expect(validAppId(bad)).toBe(false);
});
test("ACP retains app id before details are truncated",()=>{
  const turn=applyAcpUpdate(emptyTurn(),{sessionUpdate:'tool_call_update',toolCallId:'t1',title:'mcp__test__search',status:'completed',content:[{type:'content',content:{type:'text',text:`[MCP app](/home/test/.graff/mcp-apps/${id}.html)\n`+'data'.repeat(50000)}}]});
  expect(turn.tools[0].mcpAppId).toBe(id);
});
test("app store rejects traversal, oversized files and symlinks",async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'graff-app-test-'));
  try{
    await writeFile(path.join(root,`${id}.html`),'saved');expect(await readMcpApp(id,root)).toBe('saved');
    await expect(readMcpApp('../secret',root)).rejects.toThrow();
    const other='b'.repeat(32);await symlink(path.join(root,`${id}.html`),path.join(root,`${other}.html`));await expect(readMcpApp(other,root)).rejects.toThrow();
    await writeFile(path.join(root,`${id}.html`),Buffer.alloc(19*1024*1024));await expect(readMcpApp(id,root)).rejects.toThrow();
  }finally{await rm(root,{recursive:true,force:true});}
});

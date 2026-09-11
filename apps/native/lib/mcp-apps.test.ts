import {test,expect} from "bun:test";
import {mkdtemp,writeFile,symlink,rm} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {mcpAppId,viewSnapshotId,validAppId} from "./mcp-apps";
import {readMcpApp,readView} from "./snapshot-store";
import {applyAcpUpdate,emptyTurn} from "./acp";
const id="a".repeat(32);
test("only opaque local app ids are recognized",()=>{
  expect(mcpAppId(`[MCP app](/home/test/.graff/mcp-apps/${id}.html)`)).toBe(id);
  expect(mcpAppId(`[MCP app](https://evil/${id}.html)`)).toBeUndefined();
  for(const bad of ['../secret','a'.repeat(31),'A'.repeat(32),'a'.repeat(33)])expect(validAppId(bad)).toBe(false);
});
test("a rendered view is matched by its own marker and directory only",()=>{
  expect(viewSnapshotId(`[Rendered view](/home/test/.graff/views/${id}.html)`)).toBe(id);
  expect(viewSnapshotId(`[Rendered view](/home/test/.graff/mcp-apps/${id}.html)`)).toBeUndefined();
  expect(viewSnapshotId(`[Rendered view](https://evil/${id}.html)`)).toBeUndefined();
  expect(mcpAppId(`[Rendered view](/home/test/.graff/views/${id}.html)`)).toBeUndefined();
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
    // A rendered view goes through the same reader, so it inherits the same guards.
    const views=await mkdtemp(path.join(os.tmpdir(),'graff-view-test-'));
    try{
      await writeFile(path.join(views,`${id}.html`),'<h1>drawn</h1>');
      expect(await readView(id,views)).toBe('<h1>drawn</h1>');
      await expect(readView('../secret',views)).rejects.toThrow();
      await symlink(path.join(views,`${id}.html`),path.join(views,`${other}.html`));
      await expect(readView(other,views)).rejects.toThrow();
    }finally{await rm(views,{recursive:true,force:true});}
  }finally{await rm(root,{recursive:true,force:true});}
});

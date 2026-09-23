import { test, expect } from "bun:test";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { AcpTransport } from "./acp-transport";
import { permissionRequest } from "./acp-permission";
function fixture() {
 const child = Object.assign(new EventEmitter(), {stdout:new PassThrough(),stdin:new PassThrough()});
 const lines:string[]=[]; const writes:string[]=[];
 child.stdin.on("data",chunk=>writes.push(chunk.toString()));
 const transport = new AcpTransport(child as never); transport.subscribe(line=>lines.push(line));
 return {child,transport,lines,writes};
}
const request={jsonrpc:"2.0",id:"graff-permission-1",method:"session/request_permission",params:{sessionId:"s",toolCall:{toolCallId:"call1",title:"run command"},options:[{optionId:"once",name:"Allow once",kind:"allow_once"},{optionId:"always",name:"Always allow command",kind:"allow_always"},{optionId:"reject",name:"Reject",kind:"reject_once"}]}};
test("permission replies bind process, session, original ID and offered option exactly once",()=>{
 const f=fixture(); f.child.stdout.write(JSON.stringify(request)+"\n");
 const r=permissionRequest(JSON.parse(f.lines[0]))!;
 expect(r.requestId).not.toBe(request.id);
 expect(f.transport.respondPermission(r.requestId,"other","once")).toBe(false);
 expect(f.transport.respondPermission(r.requestId,"s","invented")).toBe(false);
 expect(f.transport.respondPermission(r.requestId,"s","always")).toBe(true);
 expect(f.transport.respondPermission(r.requestId,"s","once")).toBe(false);
 expect(JSON.parse(f.writes[0])).toEqual({jsonrpc:"2.0",id:request.id,result:{outcome:{outcome:"selected",optionId:"always"}}});
 const replacement=fixture(); replacement.child.stdout.write(JSON.stringify(request)+"\n");
 expect(replacement.transport.respondPermission(r.requestId,"s","once")).toBe(false);
});
test("cancel, prompt finish and child exit invalidate pending permissions",()=>{
 for(const finish of ["cancel","finish","exit"]){
  const f=fixture();f.child.stdout.write(JSON.stringify(request)+"\n");const r=permissionRequest(JSON.parse(f.lines[0]))!;
  if(finish==="cancel") f.transport.notify("session/cancel",{sessionId:"s"});
  else if(finish==="finish") f.transport.clearPermissions(); else f.child.emit("close",1,null);
  expect(f.transport.respondPermission(r.requestId,"s","once")).toBe(false);
 }
 const f=fixture();f.child.stdout.write(JSON.stringify(request)+"\n");const r=permissionRequest(JSON.parse(f.lines[0]))!;
 expect(f.transport.respondPermission(r.requestId,"s",null)).toBe(true);
 expect(JSON.parse(f.writes[0]).result.outcome).toEqual({outcome:"cancelled"});
});

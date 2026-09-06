import {test} from 'node:test';
import assert from 'node:assert/strict';
import {prompt} from './acp-client';
const chunk = {method:'session/update',params:{sessionId:'test',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'Visible partial reply'}}}};
async function withWire(lines:unknown[], body:(received:unknown[])=>Promise<void>) {
  const original=globalThis.fetch, received:unknown[]=[];
  globalThis.fetch=async()=>new Response(lines.map(line=>JSON.stringify(line)).join('\n')+'\n');
  try {await body(received);} finally {globalThis.fetch=original;}
}
test('a disconnected stream preserves partial output and reports interruption',async()=>{
  await withWire([chunk],async received=>{
    await assert.rejects(async()=>{for await(const update of prompt('test','test','hello'))received.push(update);},/ended before/);
    assert.deepEqual(received,[chunk.params.update]);
  });
});
test('a cancelled turn produces a terminal event instead of a hanging spinner',async()=>{
  await withWire([chunk,{id:1,result:{stopReason:'cancelled'}}],async received=>{
    for await(const update of prompt('test','test','hello'))received.push(update);
    assert.deepEqual(received.at(-1),{sessionUpdate:'gui_turn_end',stopReason:'cancelled'});
  });
});
test('a bridge error is surfaced after any already delivered text',async()=>{
  await withWire([chunk,{id:1,error:{message:'Agent exited'}}],async received=>{
    await assert.rejects(async()=>{for await(const update of prompt('test','test','hello'))received.push(update);},/Agent exited/);
    assert.equal(received.length,1);
  });
});

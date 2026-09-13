import { test, expect } from 'bun:test';
import { htmlArtifactId } from './html-artifacts';
import { applyAcpUpdate, emptyTurn } from './acp';
import { transcriptFromMessages } from './sessions';
const id='a'.repeat(32), marker=`[HTML preview](graff-html:${id})`;
test('HTML ids survive live detail bounding and saved transcript projection',()=>{
 const text=marker+'\n'+'body'.repeat(50000);
 const turn=applyAcpUpdate(emptyTurn(),{sessionUpdate:'tool_call_update',toolCallId:'t1',title:'mcp__codegraff_desktop__create_html',status:'completed',content:[{type:'content',content:{type:'text',text}}]});
 expect(turn.tools[0].htmlArtifactId).toBe(id);
 const saved=transcriptFromMessages([{role:'assistant',tool_calls:[{id:'t1',type:'function',function:{name:'mcp__codegraff_desktop__create_html',arguments:'{}'}}]},{role:'tool',tool_call_id:'t1',content:text}]);
 const assistant=saved.find(message=>message.role==='assistant');
 expect(assistant?.role==='assistant' && assistant.turn.tools[0].htmlArtifactId).toBe(id);
 expect(htmlArtifactId('[HTML preview](https://example.invalid/anything)')).toBeUndefined();
});

test('ordinary tool-result decoding retains an HTML preview reference', async()=>{
 const {applyEvent}=await import('./graff-events');
 const turn=applyEvent(emptyTurn(),{type:'tool_result',name:'mcp__codegraff_desktop__create_html',is_error:false,text:marker});
 expect(turn.tools[0].htmlArtifactId).toBe(id);
});

test('HTML preview creation and failure are not workspace file edits',()=>{
 for (const status of ['completed','failed']) {
  let turn=applyAcpUpdate(emptyTurn(),{sessionUpdate:'tool_call',toolCallId:'html',title:'mcp__codegraff_desktop__create_html',kind:'edit',status:'pending'});
  turn=applyAcpUpdate(turn,{sessionUpdate:'tool_call_update',toolCallId:'html',kind:'edit',status,content:[{type:'content',content:{type:'text',text:status==='completed'?marker:'Invalid HTML'}}]});
  expect(turn.diffs).toHaveLength(0);
  expect(turn.tools[0].icon).toBe('think');
 }
});

 test('render_html survives live and saved projection without inventing a workspace edit', () => {
  const text=`[Rendered view](/home/test/.graff/views/${id}.html)`;
  const turn=applyAcpUpdate(emptyTurn(),{sessionUpdate:'tool_call_update',toolCallId:'v1',title:'render_html',kind:'edit',status:'completed',content:[{type:'content',content:{type:'text',text}}]});
  expect(turn.tools[0].viewSnapshotId).toBe(id); expect(turn.diffs).toEqual([]);
  const saved=transcriptFromMessages([{role:'assistant',tool_calls:[{id:'v1',type:'function',function:{name:'render_html',arguments:'{}'}}]},{role:'tool',tool_call_id:'v1',content:text}]);
  expect(saved[0].role==='assistant' && saved[0].turn.tools[0].viewSnapshotId).toBe(id);
 });

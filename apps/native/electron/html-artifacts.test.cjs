const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises'), path=require('node:path'), os=require('node:os');
const {callTool,tools}=require('./desktop-tools.cjs');
const {saveHtml,readHtml,MAX_BYTES}=require('./html-artifacts.cjs');
test('create_html returns a private replayable reference and keeps the full original source',async()=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'graff-html-'));
 try{
  assert.ok(tools.find(tool=>tool.name==='create_html').inputSchema.required.includes('html'));
  const value={title:'Explanation',html:'<details><summary>Hello 😀</summary>Full source</details>\n'};
  const reply=await callTool('create_html',value,{HOME:home});
  const id=/graff-html:([a-f0-9]{32})/.exec(reply.content[0].text)[1];
  assert.deepEqual(await readHtml(id,home),value);
  assert.equal((await fs.stat(path.join(home,'.graff/html-artifacts',id+'.json'))).mode & 0o777,0o600);
  assert.ok(!reply.content[0].text.includes(value.html));
  await assert.rejects(saveHtml({title:'x',html:'😀'.repeat(MAX_BYTES/3)},home),/bytes/);
  await assert.rejects(saveHtml({...value,path:'/tmp/unwanted'},home),/only/);
  await assert.rejects(readHtml('../outside',home),/Invalid/);
  const link='a'.repeat(32);await fs.symlink(path.join(home,'.graff/html-artifacts',id+'.json'),path.join(home,'.graff/html-artifacts',link+'.json'));
  await assert.rejects(readHtml(link,home));
 }finally{await fs.rm(home,{recursive:true,force:true});}
});
test('preview store rejects a redirected directory',async()=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'graff-html-'));
 try{await fs.symlink(os.tmpdir(),path.join(home,'.graff'));await assert.rejects(saveHtml({title:'x',html:'hello'},home),/directory/);}
 finally{await fs.rm(home,{recursive:true,force:true});}
});

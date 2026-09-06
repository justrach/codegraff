const {test,after}=require('node:test');
const assert=require('node:assert/strict');const {execFileSync}=require('node:child_process');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');
const {Terminals,frame}=require('./terminal.cjs');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'graff-pty-test-')),binary=path.join(temp,'pty');
if(process.platform==='darwin')execFileSync('xcrun',['clang','-O2',path.join(__dirname,'native/terminal.c'),'-o',binary]);
after(()=>fs.rmSync(temp,{recursive:true,force:true}));
const wait=async condition=>{for(let i=0;i<200;i++){if(condition())return;await new Promise(r=>setTimeout(r,20));}throw Error('PTY timed out');};
test('PTY frames preserve input bytes and resize dimensions',()=>{
 const value=frame(0,Buffer.from('hello\r'));assert.equal(value.readUInt32LE(1),6);assert.equal(value.subarray(5).toString(),'hello\r');
});
test('real workspace PTY supports input, resize, interrupt, hide and cleanup',{skip:process.platform!=='darwin'},async()=>{
 const cwd=path.join(temp,'folder with spaces');fs.mkdirSync(cwd);let output='';
 const manager=new Terminals(binary,event=>{if(event.data){output+=event.data;manager.command('ack',{id:event.id,length:event.data.length});}},{shell:'/bin/sh'});
 try {
  const opened=manager.command('open',{cwd}),id=opened.id;assert.ok(opened.pid);
  manager.command('resize',{id,cols:99,rows:31});manager.command('input',{id,data:"printf '\\nPTY_READY\\n'; pwd; stty size\r"});
  await wait(()=>output.includes('31 99'));assert.ok(output.includes(cwd));
  manager.command('input',{id,data:'sleep 30\r'});await new Promise(r=>setTimeout(r,100));manager.command('input',{id,data:'\x03'});
  manager.command('input',{id,data:"printf '\\nAFTER_INTERRUPT\\n'\r"});await wait(()=>output.includes('\r\nAFTER_INTERRUPT\r\n'));
  manager.command('detach',{id});manager.command('input',{id,data:"printf '\\nWHILE_HIDDEN\\n'\r"});await wait(()=>manager.sessions.get(id).history.includes('\r\nWHILE_HIDDEN\r\n'));
  const reopened=manager.command('open',{cwd});assert.equal(reopened.pid,opened.pid);assert.ok(reopened.history.includes('WHILE_HIDDEN'));
  assert.throws(()=>manager.command('resize',{id,cols:-1,rows:2}),/size/);
  assert.throws(()=>manager.command('input',{id,data:'x'.repeat(131073)}),/large/);
  const child=manager.sessions.get(id).child;manager.command('close',{id});await wait(()=>child.exitCode!==null||child.signalCode!==null);assert.equal(manager.sessions.size,0);
 }finally{manager.closeAll();}
});
test('terminal rejects a file as a workspace and starts no shell',()=>{
 const manager=new Terminals(binary,()=>{});const file=path.join(temp,'file');fs.writeFileSync(file,'x');
 assert.throws(()=>manager.open(file),/folder/);assert.equal(manager.sessions.size,0);
});

test('ending a noisy terminal releases a helper blocked by renderer backpressure',{skip:process.platform!=='darwin'},async()=>{
 const manager=new Terminals(binary,()=>{},{shell:'/bin/sh'});
 try {
  const {id}=manager.open(temp),slot=manager.sessions.get(id);
  manager.command('input',{id,data:'yes terminal-output\r'});
  await wait(()=>slot.child.stdout.isPaused());
  assert.ok(slot.history.length<=128*1024);
  manager.command('close',{id});
  await wait(()=>slot.child.exitCode!==null||slot.child.signalCode!==null);
 }finally{manager.closeAll();}
});

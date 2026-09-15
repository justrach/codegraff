const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { startServer } = require('./server.cjs');

test('desktop shutdown is bounded when the backend ignores its drain request', {timeout:20000}, async () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(),'graff-shutdown-timeout-'));
  fs.mkdirSync(path.join(temp,'ui'));
  fs.symlinkSync(process.execPath,path.join(temp,'bun'));
  fs.writeFileSync(path.join(temp,'ui/server.js'), `
    const http=require('node:http'),fs=require('node:fs');
    http.createServer((req,res)=>{
      if(req.method==='GET'){res.end('ready');return;}
      let body='';req.on('data',chunk=>body+=chunk);
      req.on('end',()=>fs.writeFileSync('request.json',JSON.stringify({body:JSON.parse(body),token:req.headers['x-graff-desktop']})));
    }).listen(Number(process.env.PORT),process.env.HOSTNAME);
  `);
  let backend;
  try {
    backend = await startServer(temp,temp,'fixture-token',path.join(temp,'logs'));
    const started = Date.now();
    const first = backend.stop();
    assert.equal(backend.stop(),first,'concurrent quits should share shutdown');
    await first;
    assert(Date.now()-started<15000,'backend drain exceeded its bound');
    if(backend.child.exitCode===null&&backend.child.signalCode===null)await once(backend.child,'exit');
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(temp,'ui/request.json'),'utf8')),{body:{method:'shutdown'},token:'fixture-token'});
    await assert.rejects(fetch(backend.origin,{signal:AbortSignal.timeout(1000)}));
  } finally {
    if(backend&&backend.child.exitCode===null&&backend.child.signalCode===null){backend.child.kill('SIGKILL');await once(backend.child,'exit');}
    fs.rmSync(temp,{recursive:true,force:true});
  }
});

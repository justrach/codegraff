import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, writeFileSync, openSync, closeSync, readFileSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runDesktopProcess } from './test-electron.mjs';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url), repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const bundle=path.resolve(process.argv[2]||path.join(repo,'zig-out/electron/Codegraff.app'));
const output=path.resolve(process.env.GRAFF_PACKAGED_OUTPUT||path.join(repo,'zig-out/packaged-titles'));
const temp=mkdtempSync(path.join(tmpdir(),'graff-packaged-titles-')), workspace=path.join(temp,'project');
mkdirSync(workspace);mkdirSync(path.join(temp,"scratch"));mkdirSync(output,{recursive:true});
const launcher=path.join(temp,'codegraff'), quote=value=>"'"+value.replaceAll("'","'\\''")+"'";
writeFileSync(launcher,require('../electron/cli-launcher.cjs').launcherSource(bundle).replace('>/dev/null 2>&1',`>>${quote(path.join(output,'app.log'))} 2>&1`),{mode:0o755});
const script=path.join(temp,'replies.json');writeFileSync(script,JSON.stringify([
  {tool:'bash',arguments:{command:"printf 'retained work' > proof.txt"}},
  {text:'Retained work is saved.'},
  {text:'The image of retained work is visible.'},
]));
const mcp=path.join(temp,'mcp.json');writeFileSync(mcp,'{"mcpServers":{}}');
const env=Object.fromEntries(['PATH','TMPDIR','LANG','USER','LOGNAME','SHELL'].filter(key=>process.env[key]).map(key=>[key,process.env[key]]));
Object.assign(env,{HOME:temp,TMPDIR:path.join(temp,"scratch"),LMSTUDIO_API_KEY:'local',GRAFF_NO_TELEMETRY:'1',GRAFF_FLEET:'off',GRAFF_YOLO:'1',GRAFF_NO_SMOLIFY:'1',GRAFF_NO_CODEDB_GUARD:'1',NEXT_TELEMETRY_DISABLED:'1',GRAFF_MCP_CONFIG:mcp,
 GRAFF_ELECTRON_SMOKE:path.join(output,'launch-results.json'),GRAFF_SMOKE_LAUNCH_ONLY:'1',GRAFF_SMOKE_PROFILE:path.join(temp,'profile'),GRAFF_PACKAGED_OUTPUT:output});
const log=path.join(output,'model.log'), fd=openSync(log,'w');
const model=spawn('python3',[path.join(repo,'scripts/eval/frontend_model.py'),'--script',script,'--requests',path.join(temp,'requests.json')],{env,stdio:['ignore',fd,fd]});closeSync(fd);
let modelError;model.on('error',error=>{modelError=error;});
try {
 const end=Date.now()+10000;
 while(!readFileSync(log,'utf8').includes('scripted model on')) {
  if(modelError||model.exitCode!==null||Date.now()>end)throw modelError||Error('Offline model failed to start');
  await new Promise(resolve=>setTimeout(resolve,50));
 }
 process.env.GRAFF_TEST_TIMEOUT_MS='120000';
 for(const phase of ['create','reopen']) {
  env.GRAFF_SMOKE_TITLES=phase;
  const code=await runDesktopProcess('/bin/sh',['-c','launcher=$1; shift; . "$launcher"; wait "$!"','codegraff-test',launcher,workspace],env);
  if(code!==0)throw Error(readFileSync(path.join(output,'app.log'),'utf8').slice(-7000));
  const report=JSON.parse(readFileSync(path.join(output,`titles-${phase}.json`),'utf8'));
  assert.ok(report.passed.length>=2);assert.equal(report.desktop.violations.length,0);
 }
 console.log('Packaged title creation, image prompt, process restart, legacy recovery and explicit names passed.');
} finally {
 for(const [source,target] of [[path.join(workspace,'.graff'),path.join(output,'saved-evidence')],[path.join(temp,'requests.json'),path.join(output,'requests.json')],[path.join(temp,'scratch/graff-native-attachments'),path.join(output,'images')]]) {
  try {cpSync(source,target,{recursive:true});}catch{}
 }
 model.kill('SIGTERM');rmSync(temp,{recursive:true,force:true});
}

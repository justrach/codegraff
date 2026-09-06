const {spawn}=require('node:child_process');
const {realpathSync,statSync}=require('node:fs');
const {StringDecoder}=require('node:string_decoder');
const os=require('node:os');
const LIMIT=128*1024;
function frame(kind,payload){const header=Buffer.alloc(5);header[0]=kind;header.writeUInt32LE(payload.length,1);return Buffer.concat([header,payload]);}
class Terminals {
  constructor(binary,emit,options={}){this.binary=binary;this.emit=emit;this.shell=options.shell||os.userInfo().shell||'/bin/zsh';this.sessions=new Map();}
  open(cwd){
    if(typeof cwd!=='string'||!cwd.startsWith('/')||cwd.includes('\0'))throw Error('Choose a workspace folder first.');
    const id=realpathSync(cwd);if(!statSync(id).isDirectory())throw Error('Workspace is not a folder.');
    let slot=this.sessions.get(id);
    if(!slot){
      if(this.sessions.size>=4)throw Error('Four terminals are open. End a terminal session before opening another.');
      const env={...process.env,TERM:'xterm-256color',COLORTERM:'truecolor'};
      for(const key of ['GRAFF_DESKTOP_SECRET','GRAFF_DESKTOP_TOKEN','GRAFF_DESKTOP_ENDPOINT','GRAFF_MCP_CONFIG','ELECTRON_RUN_AS_NODE','NODE_OPTIONS'])delete env[key];
      const child=spawn(this.binary,[id,this.shell],{cwd:id,env,stdio:['pipe','pipe','pipe']});
      slot={child,id,history:'',seq:0,attached:true,unacked:0,exit:null};this.sessions.set(id,slot);
      const decoder=new StringDecoder('utf8');
      const output=data=>{if(this.sessions.get(id)!==slot)return;slot.history=(slot.history+data).slice(-LIMIT);slot.seq++;if(slot.attached){slot.unacked+=data.length;this.emit({id,data,seq:slot.seq});if(slot.unacked>256*1024)child.stdout.pause();}};
      child.stdout.on('data',bytes=>output(decoder.write(bytes)));
      child.stderr.on('data',bytes=>output(bytes.toString()));
      child.stdin.on('error',()=>{});
      child.once('error',error=>{if(this.sessions.get(id)!==slot)return;output(`\r\nTerminal failed: ${error.message}\r\n`);slot.exit=1;this.emit({id,exit:1,seq:++slot.seq});});
      child.once('close',code=>{if(this.sessions.get(id)!==slot)return;const tail=decoder.end();if(tail)output(tail);slot.exit=code??1;this.emit({id,exit:slot.exit,seq:++slot.seq});});
    }
    slot.attached=true;slot.unacked=0;slot.child.stdout.resume();
    return {id,pid:slot.child.pid,history:slot.history,seq:slot.seq,exit:slot.exit};
  }
  command(action,params={}){
    if(action==='open')return this.open(params.cwd);
    if(typeof params.id!=='string')throw Error('Terminal session missing.');
    const slot=this.sessions.get(params.id);if(!slot)return;
    if(action==='ack'){if(Number.isInteger(params.length)&&params.length>0){slot.unacked=Math.max(0,slot.unacked-Math.min(params.length,LIMIT));if(slot.unacked<128*1024)slot.child.stdout.resume();}return;}
    if(action==='detach'){slot.attached=false;slot.unacked=0;slot.child.stdout.resume();return;}
    if(action==='close'){this.sessions.delete(params.id);slot.child.stdin.end();slot.child.kill('SIGTERM');return;}
    if(slot.exit!==null)throw Error('This shell has exited. Start a new session.');
    if(action==='input'){
      if(typeof params.data!=='string'||Buffer.byteLength(params.data)>LIMIT)throw Error('Terminal input is too large.');
      if(slot.child.stdin.writableLength>LIMIT*2)throw Error('Terminal input is busy.');
      slot.child.stdin.write(frame(0,Buffer.from(params.data)));return;
    }
    if(action==='resize'){
      const {cols,rows}=params;if(!Number.isInteger(cols)||!Number.isInteger(rows)||cols<2||cols>1000||rows<1||rows>500)throw Error('Invalid terminal size.');
      const payload=Buffer.alloc(4);payload.writeUInt16LE(cols,0);payload.writeUInt16LE(rows,2);slot.child.stdin.write(frame(1,payload));return;
    }
    throw Error('Unknown terminal action.');
  }
  closeAll(){for(const id of this.sessions.keys())this.command('close',{id});}
}
module.exports={Terminals,frame};

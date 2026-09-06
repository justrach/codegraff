"use client";
import {useEffect,useRef,useState} from 'react';
import type {Terminal} from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import {desktop,type TerminalEvent} from '@/lib/desktop';

export default function TerminalPane({cwd,visible,onHide}:{cwd:string;visible:boolean;onHide():void}) {
  const host=useRef<HTMLDivElement>(null),terminal=useRef<Terminal|null>(null),id=useRef<string|null>(null);
  const [height,setHeight]=useState(240),[generation,setGeneration]=useState(0),[error,setError]=useState(''),[status,setStatus]=useState('Starting shell…');
  const shown=useRef(visible);shown.current=visible;
  const start=visible||id.current!==null;
  useEffect(()=>{
    if(!start)return;
    const bridge=desktop();if(!bridge?.terminal||!bridge.terminalSubscribe){setError('The workspace terminal is available in the macOS desktop app.');return;}
    let disposed=false,off=()=>{},resize:ResizeObserver|undefined,theme:MutationObserver|undefined;
    const request=bridge.terminal;
    const send=(action:string,params:Record<string,unknown>={})=>request(action,{id:id.current,...params}).catch(e=>{if(!disposed)setError(String(e.message||e));});
    void (async()=>{
      const [{Terminal},{FitAddon}]=await Promise.all([import('@xterm/xterm'),import('@xterm/addon-fit')]);if(disposed||!host.current)return;
      const term=new Terminal({fontSize:12,fontFamily:'ui-monospace, SFMono-Regular, Menlo, monospace',scrollback:2000,allowProposedApi:false,convertEol:false,cursorBlink:false});
      const fit=new FitAddon();term.loadAddon(fit);term.open(host.current);terminal.current=term;
      const applyTheme=()=>{
        const styles=getComputedStyle(host.current!),canvas=document.createElement('canvas');canvas.width=canvas.height=1;
        const context=canvas.getContext('2d',{willReadFrequently:true});
        const color=(variable:string,fallback:string)=>{if(!context)return fallback;context.clearRect(0,0,1,1);context.fillStyle=styles.getPropertyValue(variable).trim()||fallback;context.fillRect(0,0,1,1);const bytes=context.getImageData(0,0,1,1).data;return '#'+[...bytes].slice(0,3).map(b=>b.toString(16).padStart(2,'0')).join('');};
        term.options.theme={background:color('--page','#161718'),foreground:color('--ink','#e5e7eb'),cursor:color('--accent','#059669'),selectionBackground:'#88888866'};
      };
      applyTheme();theme=new MutationObserver(applyTheme);theme.observe(document.documentElement,{attributes:true,attributeFilter:['data-theme','style','class']});
      term.onData(data=>{if(id.current)void send('input',{data});});
      term.onResize(({cols,rows})=>{if(id.current)void send('resize',{cols,rows});});
      term.attachCustomKeyEventHandler(event=>{if(event.metaKey&&event.key.toLowerCase()==='k'){if(event.type==='keydown')term.clear();event.preventDefault();return false;}return !event.metaKey;});
      let ready=false;const queued:TerminalEvent[]=[];
      const deliver=(event:TerminalEvent)=>{
        if(event.id!==id.current)return;
        if(event.data)term.write(event.data,()=>{if(!disposed)void send('ack',{length:event.data!.length});});
        if(event.exit!==undefined){term.options.disableStdin=true;setStatus(event.exit===0?'Shell exited':`Shell exited (${event.exit})`);term.write('\r\n[Session ended]\r\n');}
      };
      off=bridge.terminalSubscribe!(event=>{if(!ready)queued.push(event);else deliver(event);});
      const result=await request('open',{cwd});if(disposed){void request('detach',{id:result.id});return;}
      id.current=result.id;term.options.disableStdin=result.exit!==null;setStatus(result.exit===null?'Shell ready':`Shell exited (${result.exit})`);setError('');
      if(result.history)term.write(result.history);
      ready=true;for(const event of queued)if(event.seq>result.seq)deliver(event);queued.length=0;
      const fitVisible=()=>{if(shown.current&&host.current?.clientWidth){fit.fit();void send('resize',{cols:term.cols,rows:term.rows});}};
      resize=new ResizeObserver(fitVisible);resize.observe(host.current);fitVisible();if(shown.current)term.focus();
    })().catch(e=>{if(!disposed)setError(String(e.message||e));});
    return()=>{disposed=true;off();resize?.disconnect();theme?.disconnect();terminal.current?.dispose();terminal.current=null;if(id.current)void request('detach',{id:id.current});id.current=null;};
  },[cwd,generation,start]);
  useEffect(()=>{if(visible)terminal.current?.focus();},[visible]);
  const end=async()=>{if(id.current)await desktop()?.terminal?.('close',{id:id.current});id.current=null;setGeneration(n=>n+1);};
  return <section data-workspace-terminal aria-label="Workspace terminal" hidden={!visible} className="relative shrink-0 overflow-hidden rounded-xl border border-line bg-page text-ink" style={{height,maxHeight:'65dvh'}}>
    <div role="separator" aria-label="Resize terminal" aria-orientation="horizontal" tabIndex={0} aria-valuenow={height} aria-valuemin={120} aria-valuemax={Math.round(innerHeight*.65)}
      className="absolute inset-x-0 top-0 z-10 h-1.5 cursor-row-resize touch-none hover:bg-accent/40 focus:bg-accent/40"
      onKeyDown={event=>{if(['ArrowUp','ArrowDown'].includes(event.key)){event.preventDefault();setHeight(h=>Math.max(120,Math.min(innerHeight*.65,h+(event.key==='ArrowUp'?20:-20))));}}}
      onPointerDown={event=>{event.preventDefault();event.currentTarget.setPointerCapture(event.pointerId);}}
      onPointerMove={event=>{if(event.currentTarget.hasPointerCapture(event.pointerId)){const bottom=event.currentTarget.parentElement!.getBoundingClientRect().bottom;setHeight(Math.max(120,Math.min(innerHeight*.65,bottom-event.clientY)));}}}
      onPointerUp={event=>event.currentTarget.releasePointerCapture(event.pointerId)} />
    <header className="flex h-9 items-center gap-3 border-b border-line px-3 text-xs">
      <strong className="font-medium">Terminal</strong><span title={cwd} className="min-w-0 flex-1 truncate text-ink-3">{cwd.split('/').pop()||cwd}</span><span role="status" className="text-ink-3">{status}</span>
      <button onClick={()=>terminal.current?.clear()} title="Clear terminal (⌘K)" className="hover:text-accent-ink">Clear</button>
      <button onClick={()=>{if(id.current)void desktop()?.terminal?.('close',{id:id.current});if(terminal.current)terminal.current.options.disableStdin=true;setStatus('Shell exited');}} className="hover:text-accent-ink">End session</button>
      <button aria-label="Hide terminal" title="Hide terminal (⌘J)" onClick={onHide} className="px-1 hover:text-accent-ink">×</button>
    </header>
    {error&&<div role="alert" className="absolute inset-x-2 top-10 z-10 rounded bg-surface p-3 text-xs text-red">{error}<button onClick={()=>void end()} className="ml-3 underline">Retry</button></div>}
    {status.startsWith('Shell exited')&&<button onClick={()=>void end()} className="absolute right-4 top-11 z-10 rounded bg-surface px-3 py-1 text-xs shadow-hairline">New session</button>}
    <div ref={host} className="min-h-0 p-2" style={{height:"calc(100% - 36px)"}} />
  </section>;
}

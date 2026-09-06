'use client';
import { useState, useRef, useEffect } from 'react';
import ChatTranscript from '@/components/site/ChatTranscript';
import { AssistantBody, UserBubble } from '@/components/site/ChatBubbles';
import { emptyTurn, applyAcpUpdate, type AssistantTurn } from '@/lib/acp';
import type { Msg } from '@/components/site/harness-types';
import { applyAppearance, type Appearance } from '@/lib/appearance';
const noop = () => {};
function makeTurn(name: string): AssistantTurn {
  const turn = { ...emptyTurn(), status:'done' as const, text:'The result stays readable after tool activity.' };
  if (name === 'tools') return { ...turn, tools:Array.from({length:5000},(_,i)=>({ id:`tool-${i}`,name:'Read',chip:`file-${i}.txt`,icon:'read',status:i===4999?'error' as const:'ok' as const,atChars:0,detail:[{text:('Output '+i+'\n').repeat(2000)}] })) };
  if (name === 'output') return applyAcpUpdate(turn, {sessionUpdate:'tool_call',toolCallId:'large',title:'Diagnostics',kind:'execute',status:'completed',content:[{type:'content',content:{type:'text',text:'FIRST LINE\n'+('Long diagnostic '.repeat(200)+'\n').repeat(200)+'FINAL ERROR'}}]});
  if (name === 'text') return {...turn, text:('## A useful section\n\n'+ 'Readable long conversation content. '.repeat(30)+'\n\n').repeat(160)};
  return turn;
}
export default function StressFixture() {
  const [name,setName]=useState('tools');
  const [turn,setTurn]=useState(()=>makeTurn('tools'));
  const [stream,setStream]=useState(false);
  const scroll=useRef<HTMLDivElement>(null);
  useEffect(()=>{ if(!stream)return; const timer=setInterval(()=>setTurn(t=>({...t,status:'streaming',text:t.text+' More streamed content.'})),50);return()=>clearInterval(timer);},[stream]);
  const history:Msg[]=Array.from({length:1000},(_,i)=>i%2?{id:i,role:'assistant',turn:{...emptyTurn(),status:'done',text:`Response ${i}`}}:{id:i,role:'user',text:`Message ${i}`});
  return <><main data-graff-main className="flex h-screen flex-col bg-page text-ink">
    <nav className="flex flex-wrap gap-2 p-2">
      {['tools','output','text','history','user'].map(value=><button key={value} data-stress-case={value} onClick={()=>{setStream(false);setName(value);setTurn(makeTurn(value));}}>{value}</button>)}
      {(['light','dark','codegraff'] as Appearance[]).map(theme=><button key={theme} data-stress-theme={theme} onClick={()=>applyAppearance(theme)}>{theme}</button>)}
      <button data-stream onClick={()=>setStream(!stream)}>Stream</button>
    </nav>
    {name==='history'?<ChatTranscript key={name} messages={history} register={noop} following={false} onOpenPath={noop} onReview={noop}/>:
    <div data-stress-scroll ref={scroll} className="min-h-0 flex-1 overflow-auto p-6"><div className="mx-auto max-w-[720px]">
      {name==='user'?<UserBubble text={'verylongunbrokeninput'.repeat(5000)}/>:<AssistantBody key={name} turn={turn} following={false} scroller={scroll}/>}
    </div></div>}
    <textarea aria-label="Stress composer" className="m-3 h-20 shrink-0 rounded-lg bg-surface p-3" placeholder="Still reachable while reading long content"/>
  </main></>;
}

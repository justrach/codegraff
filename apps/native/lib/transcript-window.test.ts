import {test,expect} from 'bun:test';
import {transcriptPageStart} from './transcript-window';
import {emptyTurn} from './graff-events';
import type {Msg} from '@/components/site/harness-types';
const history=(count:number,size:number):Msg[]=>Array.from({length:count},(_,i)=>[
  {role:'user' as const,id:i*2,text:'Request '+i},
  {role:'assistant' as const,id:i*2+1,turn:{...emptyTurn(),text:'x'.repeat(size)}},
]).flat();
test('large saved replies are bounded even below the message-count limit',()=>{
  const messages=history(24,22000),start=transcriptPageStart(messages);
  expect(start).toBe(44);expect(messages.length-start).toBe(4);
  let end=messages.length,seen=0;
  while(end){const start=transcriptPageStart(messages,end);expect(start).toBeLessThan(end);seen+=end-start;end=start;}
  expect(seen).toBe(messages.length);
});
test('short history, empty history and a single oversized reply remain readable',()=>{
  expect(transcriptPageStart([])).toBe(0);
  expect(transcriptPageStart(history(2,20))).toBe(0);
  expect(transcriptPageStart(history(100,20))).toBe(120);
  expect(transcriptPageStart(history(1,200000))).toBe(0);
});

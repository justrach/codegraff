'use client';
import { useEffect, useRef } from 'react';
import { desktop } from '@/lib/desktop';
type Actions = {
  newChat():void; closeChat(id:number):void; reopenClosed():void; toggleSplit():void;
  split(direction:'row'|'column'):void; focusChat(id:number):void; zoomPane():void;
  resizePane(delta:number):void; equalize():void; openWorkspace():void; toggleTerminal():void;
  chats:{id:number}[]; columns:number[]; activeId:number;
};
export function useDesktopShortcuts(actions: Actions) {
  const ref=useRef(actions);ref.current=actions;
  useEffect(()=>{
    const dispatch=(action:string)=>{
      const a=ref.current;
      switch(action){
        case 'new':a.newChat();return true;
        case 'close':a.closeChat(a.activeId);return true;
        case 'reopen':a.reopenClosed();return true;
        case 'split-right':a.split('row');return true;
        case 'split-down':a.split('column');return true;
        case 'split-zoom':a.zoomPane();return true;
        case 'terminal':a.toggleTerminal();return true;
        case 'workspace':a.openWorkspace();return true;
      }
      return false;
    };
    const native=(event:Event)=>dispatch((event as CustomEvent<string>).detail);
    const onKey=(e:KeyboardEvent)=>{
      // Dialogs own their typing and navigation. Escape and Tab remain local.
      if(e.isComposing)return;
      if(e.target instanceof Element&&e.target.closest('[data-workspace-terminal]')&&!e.metaKey)return;
      if(document.querySelector('[role="dialog"]'))return;
      const a=ref.current,k=e.key.toLowerCase();let handled=false;
      const command=e.metaKey||e.ctrlKey;
      const cycle=(ids:number[],delta:number)=>{const index=ids.indexOf(a.activeId);const id=ids[(index+delta+ids.length)%ids.length];if(id!==undefined)a.focusChat(id);};
      if(e.ctrlKey&&!e.metaKey&&k==='tab'){cycle(a.chats.map(c=>c.id),e.shiftKey?-1:1);handled=true;}
      else if(command){
        if(e.metaKey&&e.ctrlKey&&k.startsWith('arrow')){a.resizePane(k==='arrowleft'||k==='arrowup'?-0.2:0.2);handled=true;}
        else if(e.metaKey&&e.ctrlKey&&['=','+'].includes(k)){a.equalize();handled=true;}
        else if(e.altKey&&k.startsWith('arrow')){cycle(a.columns,k==='arrowleft'||k==='arrowup'?-1:1);handled=true;}
        else if(!e.altKey){
          if(k==='j'&&!e.shiftKey)handled=dispatch('terminal');
          else if(k==='n'&&!e.shiftKey)handled=dispatch('new');
          else if(k==='t')handled=dispatch(e.shiftKey?'reopen':'new');
          else if(k==='w'&&!e.shiftKey)handled=dispatch('close');
          else if(k==='d')handled=dispatch(e.shiftKey?'split-down':'split-right');
          else if(k==='enter'&&e.shiftKey)handled=dispatch('split-zoom');
          else if(k==='o'&&!e.shiftKey)handled=dispatch('workspace');
          else if(k==='\\'){a.toggleSplit();handled=true;}
          else if(['[',']','{','}'].includes(k)){cycle(e.shiftKey?a.chats.map(c=>c.id):a.columns,k==='['||k==='{'?-1:1);handled=true;}
          else if(!e.shiftKey&&/^[1-9]$/.test(k)){const chat=k==='9'?a.chats.at(-1):a.chats[Number(k)-1];if(chat)a.focusChat(chat.id);handled=true;}
          else if(k==='enter'||(e.ctrlKey&&k==='f')){void desktop()?.windowControl?.('fullscreen');handled=true;}
          else if(['=','+','-','0'].includes(k)){void desktop()?.windowControl?.(k==='0'?'reset-zoom':k==='-'?'zoom-out':'zoom-in');handled=true;}
        }
      }
      if(handled){e.preventDefault();e.stopPropagation();}
    };
    window.addEventListener('keydown',onKey);window.addEventListener('graff-desktop-action',native);
    return()=>{window.removeEventListener('keydown',onKey);window.removeEventListener('graff-desktop-action',native);};
  },[]);
}

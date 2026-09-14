import {toSidebarRecent,type StoredSession} from '@/lib/sessions';
import type {Chat} from './harness-types';
export function sidebarRecents(stored:StoredSession[],chats:Chat[],unread:ReadonlySet<number>=new Set()) {
  const now=Date.now(),titles=new Map(chats.filter(chat=>chat.session&&chat.title).map(chat=>[chat.session,chat.title!]));
  return stored.map(session=>{const row=toSidebarRecent(session,now),title=titles.get(session.name);return {...row,...(title?{label:title}:{}),unread:chats.some(chat=>chat.session===session.name&&(session.local||!session.workspace||chat.cwd===session.workspace)&&unread.has(chat.id))};});
}
export function sessionFooterTitle(session:string|undefined,acp:string|null,cwd:string|undefined) {
  return session?`graff session ${session}${acp?` · ACP ${acp}`:''}${cwd?` · ${cwd}`:''}\nClick to copy the command that resumes it in a terminal.`:undefined;
}

import { useEffect, useMemo, useRef, useState, type SetStateAction } from 'react';
import { chatGroups, replaceChatGroup, type ChatGroup } from '@/lib/chat-groups';
import { flatSplit, insertSplit, splitIds, pruneSplit, resizeChatSplit, balanceSplit, type SplitTree } from '@/lib/split-tree';
import type { Chat } from './harness-types';

/** Open workspace tabs own layouts; individual chats still own workers and drafts. */
export function useChatGroups(chats: Chat[], activeId: number) {
  const [layouts, setLayouts] = useState<ChatGroup[]>([]);
  const chatKey = chats.map(chat => chat.id).join(',');
  const titleKey = JSON.stringify(chats.map(chat => [chat.id,chat.title]));
  const groups = useMemo(() => chatGroups(chats, layouts), [chatKey, layouts]);
  const current = groups.find(group => group.ids.includes(activeId));
  const focused = useRef(new Map<number, number>());
  if (current) focused.current.set(current.ids[0], activeId);
  useEffect(() => {
    const live = new Set(chatKey.split(',').map(Number));
    setLayouts(old => old.map(group => ({ ...group, ids: group.ids.filter(id => live.has(id)), tree: group.tree ? pruneSplit(group.tree, live) ?? undefined : undefined })).filter(group => group.ids.length));
    for (const id of focused.current.keys()) if (!live.has(id)) focused.current.delete(id);
  }, [chatKey]);
  const panes = current && current.ids.length > 1 ? current.ids : [];
  const setPanes = (update: SetStateAction<number[]>) => setLayouts(old => {
    const ids = old.find(group => group.ids.includes(activeId))?.ids ?? [];
    return replaceChatGroup(old, activeId, typeof update === 'function' ? update(ids) : update);
  });
  const tabs = useMemo(() => groups.map(group => ({
    id: group.ids[0], paneIds: group.ids, direction: group.direction, tree: group.tree,
    title: group.ids.map(id => chats.find(chat => chat.id === id)?.title ?? (chats.length > 1 ? `Chat ${id}` : 'New chat')).join(' / '),
  })), [groups,titleKey]);
  const updateTree = (apply: (tree: SplitTree) => SplitTree) => setLayouts(old => {
    const group=old.find(group=>group.ids.includes(activeId));
    if(!group)return old;
    const tree=apply(group.tree??flatSplit(group.ids,group.direction));
    return old.map(item=>item===group?{ids:splitIds(tree),tree,direction:typeof tree==='number'?'row':tree.axis}:item);
  });
  return { groups, tabs, panes, setPanes, tree: current?.tree, setTree: (tree:SplitTree)=>updateTree(()=>tree),
    resize: (delta:number)=>updateTree(tree=>resizeChatSplit(tree,activeId,delta)), balance: ()=>updateTree(balanceSplit),
    split(source:number,target:number,edge:'left'|'right'|'top'|'bottom') {
      setLayouts(old=>{
        const targetGroup=old.find(g=>g.ids.includes(target)), sourceGroup=old.find(g=>g.ids.includes(source));
        const targetIds=targetGroup?.ids??[target], sourceIds=sourceGroup?.ids??[source];
        if(targetIds.some(id=>sourceIds.includes(id))||targetIds.length+sourceIds.length>4)return old;
        const targetTree=targetGroup?.tree??flatSplit(targetIds,targetGroup?.direction??'row');
        const sourceTree=sourceGroup?.tree??flatSplit(sourceIds,sourceGroup?.direction??'row');
        const axis=edge==='left'||edge==='right'?'row':'column';
        const uniform=(tree:SplitTree):boolean=>typeof tree==='number'||tree.axis===axis&&uniform(tree.first)&&uniform(tree.second);
        let tree=insertSplit(targetTree,target,sourceTree,edge);
        if(uniform(targetTree)&&uniform(sourceTree))tree=flatSplit(splitIds(tree),axis);
        return [...old.filter(g=>g!==targetGroup&&g!==sourceGroup),{ids:splitIds(tree),tree,direction:typeof tree==='number'?'row' as const:tree.axis}];
      });
    }, direction: current?.direction ?? 'row',
    activeTab: current?.ids[0] ?? activeId,
    focusOf: (id: number) => {
      const group = groups.find(group => group.ids.includes(id));
      const previous = group && focused.current.get(group.ids[0]);
      return previous && group?.ids.includes(previous) ? previous : id;
    },
    remove(ids: number[]) { setLayouts(old => old.map(group => { const live=group.ids.filter(id=>!ids.includes(id)); return {...group,ids:live,...(group.tree?{tree:pruneSplit(group.tree,new Set(live))??undefined}:{})}; }).filter(group => group.ids.length)); },
  };
}

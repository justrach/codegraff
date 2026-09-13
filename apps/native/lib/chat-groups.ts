import { pruneSplit, type SplitTree } from './split-tree';
export type ChatGroup = { ids: number[]; direction: 'row' | 'column'; tree?: SplitTree };
export function chatGroups(chats: { id: number }[], layouts: ChatGroup[]): ChatGroup[] {
  const live = new Set(chats.map(chat => chat.id)), seen = new Set<number>();
  return chats.flatMap(chat => {
    if (seen.has(chat.id)) return [];
    const saved = layouts.find(group => group.ids.includes(chat.id));
    const ids = (saved?.ids ?? [chat.id]).filter(id => live.has(id) && !seen.has(id));
    ids.forEach(id => seen.add(id));
    const tree = saved?.tree ? pruneSplit(saved.tree, new Set(ids)) ?? undefined : undefined;
    return [{ ids, direction: tree && typeof tree !== 'number' ? tree.axis : saved?.direction ?? 'row', ...(tree ? {tree} : {}) }];
  });
}
export function replaceChatGroup(layouts: ChatGroup[], active: number, ids: number[]): ChatGroup[] {
  const direction = layouts.find(group => group.ids.includes(active))?.direction ?? 'row';
  const kept = layouts.filter(group => !group.ids.includes(active)).map(group => ({ ...group, ids: group.ids.filter(id => !ids.includes(id)) })).filter(group => group.ids.length);
  return ids.length ? [...kept, { ids: [...new Set(ids)], direction }] : kept;
}
export function mergeChatGroups(target: number[], source: number[], at: number, after: boolean): number[] | null {
  if (!target.includes(at) || source.some(id => target.includes(id))) return null;
  if (target.length + source.length > 4) return null;
  const ids = [...target]; ids.splice(ids.indexOf(at) + Number(after), 0, ...source);
  return ids;
}
export function reorderChatGroups<T extends { id: number }>(chats: T[], groups: ChatGroup[], source: number, target: number, after: boolean): T[] {
  const moving = groups.find(group => group.ids.includes(source)), destination = groups.find(group => group.ids.includes(target));
  if (!moving || !destination || moving === destination) return chats;
  const order = groups.filter(group => group !== moving);
  order.splice(order.indexOf(destination) + Number(after), 0, moving);
  return order.flatMap(group => group.ids.map(id => chats.find(chat => chat.id === id)!));
}

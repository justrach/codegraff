import { test, expect } from 'bun:test';
import { chatGroups, replaceChatGroup, mergeChatGroups, reorderChatGroups } from './chat-groups';
test('closing an entire side preserves the remaining nested split axis',()=>{
  const tree={key:'root',axis:'row' as const,ratio:.5,first:1,second:{key:'nested',axis:'column' as const,ratio:.5,first:2,second:3}};
  const [group]=chatGroups([{id:2},{id:3}],[{ids:[1,2,3],direction:'row',tree}]);
  expect(group.direction).toBe('column');
  expect(group.tree).toBe(tree.second);
  expect(group.ids).toEqual([2,3]);
});
test('a split has one tab; independent splits keep their ordering and direction', () => {
  const chats = [1,2,3,4,5].map(id => ({id}));
  const layouts = [{ids:[2,1],direction:'column' as const},{ids:[3,4],direction:'row' as const}];
  expect(chatGroups(chats,layouts)).toEqual([...layouts,{ids:[5],direction:'row'}]);
  expect(chatGroups(chats.filter(c=>c.id!==2),layouts)[0]).toEqual({ids:[1],direction:'column'});
  expect(reorderChatGroups(chats,chatGroups(chats,layouts),2,3,true).map(c=>c.id)).toEqual([3,4,2,1,5]);
});
test('merging and ungrouping preserve other tabs and enforce the pane cap', () => {
  const layouts = [{ids:[1,2],direction:'column' as const},{ids:[3,4],direction:'row' as const}];
  expect(mergeChatGroups([1,2],[3,4],2,true)).toEqual([1,2,3,4]);
  expect(mergeChatGroups([1,2,3],[4,5],2,true)).toBeNull();
  expect(mergeChatGroups([1,2],[1,2],1,true)).toBeNull();
  expect(replaceChatGroup(layouts,1,[1,2,3,4])).toEqual([{ids:[1,2,3,4],direction:'column'}]);
  expect(replaceChatGroup(layouts,1,[])).toEqual([layouts[1]]);
});

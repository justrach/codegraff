import {test, expect} from 'bun:test';
import {reorderTabs, splitTab} from './tab-drop';
test('reordering tabs preserves the conversation objects and active pane order', () => {
  const tabs = [{id:1, draft:'first'}, {id:2, draft:'second'}, {id:3, draft:'third'}];
  const next = reorderTabs(tabs, 1, 3, true);
  expect(next.map(t=>t.id)).toEqual([2,3,1]);
  expect(next[2]).toBe(tabs[0]);
  expect(reorderTabs(tabs,1,1,true)).toBe(tabs);
});
test('splitting moves an existing chat without duplicates and respects the cap', () => {
  expect(splitTab([1],2,1,'right')).toEqual([1,2]);
  expect(splitTab([1],2,1,'top')).toEqual([2,1]);
  expect(splitTab([1,2,3],3,1,'left')).toEqual([3,1,2]);
  expect(splitTab([1,2,3,4],5,1,'right')).toBeNull();
  expect(splitTab([1,2,3,4],4,1,'right')).toEqual([1,4,2,3]);
  expect(splitTab([1],1,1,'right')).toBeNull();
});

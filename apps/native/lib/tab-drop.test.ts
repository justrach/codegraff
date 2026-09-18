import {test, expect} from 'bun:test';
import {reorderTabs, sidebarRowDrop, splitTab} from './tab-drop';
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
test('sidebar rows split on the outer thirds and reorder in the middle', () => {
  const rect = { left: 0, top: 0, width: 100, height: 32 };
  expect(sidebarRowDrop(1, 2, 10, 8, rect)).toEqual({ kind: "split", id: 2, edge: "left" });
  expect(sidebarRowDrop(1, 2, 90, 8, rect)).toEqual({ kind: "split", id: 2, edge: "right" });
  expect(sidebarRowDrop(1, 2, 50, 8, rect)).toEqual({ kind: "tab", id: 2, after: false });
  expect(sidebarRowDrop(1, 2, 50, 24, rect)).toEqual({ kind: "tab", id: 2, after: true });
  expect(sidebarRowDrop(2, 2, 10, 8, rect)).toBeNull();
});

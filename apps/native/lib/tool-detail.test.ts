import { test, expect } from 'bun:test';
import { applyAcpUpdate, emptyTurn } from './acp';
import { boundToolDetail, TOOL_DETAIL_LIMIT } from './tool-detail';
test('tool results preserve multiple lines and long diagnostics', () => {
  const text = 'first line\n' + 'long diagnostic '.repeat(100) + '\nfinal failure';
  const turn = applyAcpUpdate(emptyTurn(), { sessionUpdate:'tool_call', toolCallId:'read', title:'Read', kind:'read', status:'completed', content:[{type:'content',content:{type:'text',text}}] });
  expect(turn.tools[0].detail[0].text).toBe(text);
});
test('oversized GUI output keeps the head and tail with an explicit omission', () => {
  const text = 'START' + 'x'.repeat(TOOL_DETAIL_LIMIT * 3) + 'FINAL ERROR';
  const result = boundToolDetail([{text}]).map(row => row.text).join('\n');
  expect(result.startsWith('START')).toBe(true); expect(result.endsWith('FINAL ERROR')).toBe(true);
  expect(result).toContain('omitted'); expect(result.length).toBeLessThan(TOOL_DETAIL_LIMIT);
});

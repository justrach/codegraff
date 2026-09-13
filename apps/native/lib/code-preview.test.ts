import { expect, test } from 'bun:test';
import { codePreview } from './code-preview';

test('short code preserves exact source, including trailing newlines', () => {
  for (const source of ['', 'hello\n\n', Array(120).fill('😀').join('\r\n') + '\r\n']) {
    expect(codePreview(source).text).toBe(source);
    expect(codePreview(source).collapsible).toBe(false);
  }
});

test('the first code above the threshold previews sixty complete lines', () => {
  const lines = Array.from({ length: 121 }, (_, i) => `const value${i} = '😀';`);
  for (const newline of ['\n', '\r\n']) {
    const source = lines.join(newline) + newline;
    const preview = codePreview(source);
    expect(preview.collapsible).toBe(true);
    expect(preview.lines).toBe(121);
    expect(preview.text.replace(/\r$/, '')).toBe(lines.slice(0, 60).join(newline));
    expect(source).toEndWith(lines[120] + newline);
  }
});

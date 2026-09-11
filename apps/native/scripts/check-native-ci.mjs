import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
export function validateCoverage(native, visual, stress) {
  assert.ok(['passed', 'passed-with-skips'].includes(native?.status), 'Native Activity and graphical-session checks did not pass');
  assert.equal(visual?.mode, 'foreground', 'CI must exercise foreground presentation');
  assert.equal(visual?.status, 'passed', 'CI cannot silently skip foreground GUI checks');
  assert.equal(stress?.fullscreen, 'passed', 'CI must exercise native fullscreen and reload');
}
if (path.resolve(process.argv[1] || '') === fileURLToPath(import.meta.url)) {
const read = file => {
  try { return JSON.parse(fs.readFileSync(path.join(root, 'zig-out', file), 'utf8')); }
  catch { return null; }
};
const native = read('native-tests/native-results.json');
const visual = read('visual-tests/test-run.json');
const stress = read('visual-tests/stress-results.json');
if (process.argv[2] === '--summary') {
  const lines = ['## Native macOS GUI coverage', '',
    `- Native checks: ${native?.status ?? 'no report'}`,
    ...(native?.passed ?? []).map(name => `- Passed: ${name}`),
    ...(native?.skipped ?? []).map(name => `- **Skipped:** ${name}`),
    `- Foreground GUI suite: ${visual?.status ?? 'no report'}`,
    `- Fullscreen transition and reload: ${stress?.fullscreen ?? 'no report'}`, '',
    'OS input and display capture require permissions granted to the runner. Missing permissions do not count as passed.', ''];
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, lines.join('\n'));
  else console.log(lines.join('\n'));
} else {
  validateCoverage(native, visual, stress);
  console.log('Required native GUI and fullscreen checks passed.');
}
}

const { createTestWindowPolicy } = require('./test-window-policy.cjs');
// Requiring this module is explicit: only test entrypoints and fixtures use it.
const policy = createTestWindowPolicy(require('electron'));
const buttons = new WeakMap();
const attachTestDebugger = wc => { if (!wc.debugger.isAttached()) wc.debugger.attach('1.3'); };
async function focusTestPage(wc) {
  if (policy.foreground) {
    wc.focus();
    return;
  }
  // WebContents.focus() can still activate macOS even when the BrowserWindow is
  // unfocusable and the app policy is prohibited. Emulate focus in Chromium only.
  wc.setBackgroundThrottling(false);
  attachTestDebugger(wc);
  await wc.debugger.sendCommand('Emulation.setFocusEmulationEnabled', { enabled: true });
}
const modifierBits = list => (list ?? []).reduce((bits, name) => bits | ({ alt: 1, control: 2, ctrl: 2, meta: 4, shift: 8 }[name] ?? 0), 0);
async function testInput(wc, event) {
  await focusTestPage(wc);
  // Await Chromium dispatch in both window modes. sendInputEvent returns before
  // the renderer has handled it, letting subsequent layout assertions race it.
  // Real macOS pointer/keyboard coverage uses ComputerUse in the native suite.
  attachTestDebugger(wc);
  const modifiers = modifierBits(event.modifiers);
  if (event.type === 'char') return wc.debugger.sendCommand('Input.dispatchKeyEvent', { type: 'char', text: event.keyCode, modifiers });
  if (event.type.startsWith('key')) {
    const key = event.keyCode === 'Return' ? 'Enter' : event.keyCode === 'Space' ? ' ' : event.keyCode;
    const code = { Tab: 9, Enter: 13, Escape: 27, Backspace: 8, Delete: 46, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 }[key]
      ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : undefined);
    if (code === undefined) throw Error(`Unsupported test key: ${key}`);
    return wc.debugger.sendCommand('Input.dispatchKeyEvent', { type: event.type, key,
      code: key === ' ' ? 'Space' : key.length === 1 ? `Key${key.toUpperCase()}` : key, windowsVirtualKeyCode: code, modifiers,
      ...(key === 'Enter' && event.type === 'keyDown' && !modifiers ? { text: '\r' } : {}) });
  }
  const type = { mouseDown: 'mousePressed', mouseUp: 'mouseReleased', mouseMove: 'mouseMoved', mouseWheel: 'mouseWheel' }[event.type];
  if (!type) throw Error(`Unsupported test input: ${event.type}`);
  const bit = { left: 1, right: 2, middle: 4 }[event.button] ?? 0;
  const pressed = event.type === 'mouseDown' ? (buttons.get(wc) ?? 0) | bit
    : event.type === 'mouseUp' ? (buttons.get(wc) ?? 0) & ~bit : buttons.get(wc) ?? 0;
  buttons.set(wc, pressed);
  return wc.debugger.sendCommand('Input.dispatchMouseEvent', { type, x: event.x, y: event.y,
    button: event.button ?? (pressed & 1 ? 'left' : 'none'), buttons: pressed,
    clickCount: event.clickCount ?? 0, modifiers,
    ...(type === 'mouseWheel' ? { deltaX: -(event.deltaX ?? 0), deltaY: -(event.deltaY ?? 0) } : {}) });
}
async function pressEnter(wc) {
  await testInput(wc, { type: 'keyDown', keyCode: 'Return' });
  await testInput(wc, { type: 'keyUp', keyCode: 'Return' });
}
async function describeWorkspace(wc) {
  try {
    return await wc.executeJavaScript(`(() => {
      const main = document.querySelector('[data-graff-main]');
      return JSON.stringify({
        ready: main?.getAttribute('data-workspace-ready'),
        prompt: !!document.querySelector('textarea[aria-label="Prompt"]'),
        onboarded: document.documentElement.dataset.graffOnboarded || '',
        world: window.__GRAFF_ONBOARDED__ === true,
        gallery: window.__GRAFF_GALLERY__ === true,
        dismissed: (() => { try { return localStorage.getItem('graff.onboarding.dismissed') || ''; } catch { return ''; } })(),
        onboard: !!document.querySelector('[data-onboarding]'),
        modal: document.querySelector('[aria-modal="true"]')?.getAttribute('aria-label') || '',
        text: (document.body?.innerText || '').replace(/\\s+/g, ' ').slice(0, 280),
      });
    })()`);
  } catch (error) {
    return String(error);
  }
}
module.exports = { ...policy, attachTestDebugger, focusTestPage, testInput, pressEnter, describeWorkspace };

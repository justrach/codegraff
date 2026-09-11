const fs = require('node:fs'), path = require('node:path');
// Optional renderer-only recording: never captures or activates the desktop.
async function recordTabMotion(wc, output) {
  if (process.env.GRAFF_CAPTURE_TAB_MOTION !== '1') return async () => {};
  const directory = path.join(output, 'tab-motion'); fs.mkdirSync(directory, { recursive: true });
  const frames = [];
  if (!wc.debugger.isAttached()) wc.debugger.attach('1.3');
  const listener = (_event, method, params) => {
    if (method !== 'Page.screencastFrame') return;
    const name = `frame-${String(frames.length).padStart(4, '0')}.jpg`;
    fs.writeFileSync(path.join(directory, name), Buffer.from(params.data, 'base64'));
    frames.push({ name, time: params.metadata.timestamp });
    void wc.debugger.sendCommand('Page.screencastFrameAck', { sessionId: params.sessionId }).catch(() => {});
  };
  wc.debugger.on('message', listener);
  await wc.debugger.sendCommand('Page.startScreencast', { format: 'jpeg', quality: 85, maxWidth: 1320, maxHeight: 850, everyNthFrame: 1 });
  return async () => {
    await wc.debugger.sendCommand('Page.stopScreencast'); wc.debugger.removeListener('message', listener);
    fs.writeFileSync(path.join(directory, 'frames.txt'), frames.map((frame, i) =>
      `file '${frame.name}'\nduration ${Math.max(1/60, Math.min(2, (frames[i+1]?.time ?? frame.time+1)-frame.time))}`
    ).join('\n') + (frames.length ? `\nfile '${frames.at(-1).name}'\n` : ''));
  };
}
module.exports = { recordTabMotion };

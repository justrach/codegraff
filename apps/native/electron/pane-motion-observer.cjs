const { attachTestDebugger } = require('./test-desktop.cjs');

// Observe native animation starts, including animations that finish before the
// test process gets its next IPC turn. Do not alter playback or the app's code.
async function observePaneMotion(wc) {
  attachTestDebugger(wc);
  const started = [];
  const listener = (_event, method, params) => {
    if (method === 'Animation.animationStarted' && params.animation.type === 'WebAnimation')
      started.push(params.animation);
  };
  wc.debugger.on('message', listener);
  await wc.debugger.sendCommand('Animation.enable');
  return {
    async assertStarted() {
      for (let attempt = 0; attempt < 100; attempt++) {
        for (const animation of started.splice(0)) {
          if (!(animation.source?.duration > 1) || !animation.source.backendNodeId) continue;
          const { node } = await wc.debugger.sendCommand('DOM.describeNode', { backendNodeId: animation.source.backendNodeId });
          if (node.attributes?.some((value, i) => i % 2 === 0 && value === 'data-chat')) return;
        }
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw Error('The downward drop did not start a native pane animation');
    },
    async stop() {
      wc.debugger.removeListener('message', listener);
      await wc.debugger.sendCommand('Animation.disable');
    },
  };
}
module.exports = { observePaneMotion };

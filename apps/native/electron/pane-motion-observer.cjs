// Retain evidence from the real Web Animations API in the renderer. Hidden
// compositors do not consistently forward CDP animation lifecycle events.
async function observePaneMotion(wc) {
  await wc.executeJavaScript(`(()=>{
    const original = Element.prototype.animate;
    const state = { started: 0, finished: 0, original };
    window.__paneMotionObservation = state;
    Element.prototype.animate = function(...args) {
      const animation = original.apply(this, args);
      if (this.matches('[data-chat]') && Number(animation.effect.getTiming().duration) > 1) {
        animation.ready.then(() => { state.started++; }, () => {});
        animation.finished.then(() => { state.finished++; }, () => {});
      }
      return animation;
    };
  })()`);
  return {
    async assertStarted() {
      for (let attempt = 0; attempt < 100; attempt++) {
        if (await wc.executeJavaScript('window.__paneMotionObservation.started > 0 && window.__paneMotionObservation.finished > 0')) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw Error('The downward drop did not run a native pane animation to completion');
    },
    async stop() {
      await wc.executeJavaScript(`(()=>{
        Element.prototype.animate = window.__paneMotionObservation.original;
        delete window.__paneMotionObservation;
      })()`);
    },
  };
}
module.exports = { observePaneMotion };

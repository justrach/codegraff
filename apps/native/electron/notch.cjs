const fs = require('node:fs');
const path = require('node:path');

function notchStore(directory) {
  const file = path.join(directory, 'observer-notch.json');
  return {
    load() {
      try {
        const data = JSON.parse(fs.readFileSync(file, 'utf8'));
        return data.enabled !== false;
      } catch {
        return true;
      }
    },
    save(enabled) {
      fs.mkdirSync(directory, { recursive: true });
      fs.writeFileSync(file, JSON.stringify({ enabled: !!enabled }), { mode: 0o600 });
    },
  };
}

function createNotch({ native, store, activate, allow = true }) {
  let enabled = allow && store.load();
  const apply = snapshot => {
    if (!native) return;
    if (!enabled) {
      native.hideNotch();
      return;
    }
    native.updateNotch(JSON.stringify(snapshot || { sessions: [] }));
  };
  if (enabled) apply({ sessions: [] });
  return {
    enabled: () => enabled,
    setEnabled(on) {
      if (!allow) return false;
      enabled = !!on;
      store.save(enabled);
      if (enabled) apply({ sessions: [] });
      else native?.hideNotch();
      return enabled;
    },
    update: apply,
    hide() { native?.hideNotch(); },
    inspect() {
      if (!native?.inspectNotch) return null;
      try { return JSON.parse(native.inspectNotch()); } catch { return null; }
    },
    clicked(id) {
      activate?.(id);
    },
  };
}

module.exports = { notchStore, createNotch };

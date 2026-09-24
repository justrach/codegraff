function transitionOptions(action, activeTurns) {
  if (activeTurns < 1) return null;
  const count = activeTurns === 1 ? 'One chat has' : `${activeTurns} chats have`;
  return {
    type: 'warning', title: `${action} Codegraff?`,
    message: `${count} a turn in progress.`,
    detail: 'Continuing will interrupt the running turn. Open chat tabs and saved conversation checkpoints will be available when Codegraff returns.',
    buttons: [`${action} and interrupt`, 'Keep working'], defaultId: 1, cancelId: 1, noLink: true,
  };
}

async function confirmTransition(win, dialog, action, activeTurns) {
  const options = transitionOptions(action, activeTurns);
  if (!options) return true;
  const { response } = await dialog.showMessageBox(win, options);
  return response === 0;
}

function installTransitionGuard({ win, ipcMain, trusted, dialog }) {
  let activeTurns = 0, approvedUnload = false;
  ipcMain.on('active-turns', (event, count) => {
    trusted(event);
    if (Number.isSafeInteger(count) && count >= 0 && count <= 50) activeTurns = count;
  });
  const preflight = async action => {
    if (!await confirmTransition(win, dialog, action, activeTurns)) return false;
    if (activeTurns > 0) {
      approvedUnload = true;
      setTimeout(() => { approvedUnload = false; }, 10_000).unref();
    }
    return true;
  };
  const reload = async () => { if (await preflight('Reload') && !win.isDestroyed()) win.webContents.reload(); };
  win.webContents.on('will-prevent-unload', event => {
    if (approvedUnload) { approvedUnload = false; event.preventDefault(); return; }
    const options = transitionOptions('Leave', activeTurns);
    if (!options || dialog.showMessageBoxSync(win, options) === 0) event.preventDefault();
  });
  return { preflight, reload };
}

module.exports = { transitionOptions, confirmTransition, installTransitionGuard };

// Isolated-world preload: same origin localStorage as the page, before AccountChrome hydrates.
try {
  window.__GRAFF_ONBOARDED__ = true;
  localStorage.setItem('graff.onboarding.dismissed', 'true');
} catch { /* optional storage */ }

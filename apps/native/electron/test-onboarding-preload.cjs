// Isolated-world preload: mark the shared DOM before AccountChrome hydrates.
// window.__GRAFF_ONBOARDED__ stays isolated; data-graff-onboarded is page-visible.
try {
  window.__GRAFF_ONBOARDED__ = true;
  document.documentElement.dataset.graffOnboarded = '1';
  localStorage.setItem('graff.onboarding.dismissed', 'true');
} catch { /* optional storage */ }

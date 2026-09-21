// Isolated-world preload: same origin localStorage as the page, before AccountChrome hydrates.
try { localStorage.setItem('graff.onboarding.dismissed', 'true'); } catch { /* optional storage */ }

/* Can I Self-Host It? — interactions. No framework, on purpose: a directory
   about running your own software should not need 40 kB of someone else's.
   Phase 0 scope: the theme toggle, and nothing else. */
(() => {
  const root = document.documentElement;
  const system = matchMedia('(prefers-color-scheme: dark)');

  const stored = () => {
    try {
      const v = localStorage.getItem('theme');
      return v === 'light' || v === 'dark' ? v : null;
    } catch {
      return null;
    }
  };

  const current = () =>
    root.dataset.theme === 'dark' || root.dataset.theme === 'light'
      ? root.dataset.theme
      : system.matches
        ? 'dark'
        : 'light';

  document.querySelector('[data-toggle-theme]')?.addEventListener('click', () => {
    const next = current() === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try {
      localStorage.setItem('theme', next);
    } catch {
      /* storage disabled — the choice just won't outlive the tab */
    }
  });

  // No stored choice means the OS is still in charge: follow it live, so a
  // machine that flips to dark at sunset doesn't need a reload.
  system.addEventListener('change', (e) => {
    if (!stored()) root.dataset.theme = e.matches ? 'dark' : 'light';
  });
})();

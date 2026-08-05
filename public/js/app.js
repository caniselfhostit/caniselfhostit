/* Can I Self-Host It? — interactions. No framework, on purpose: a directory
   about running your own software should not need 40 kB of someone else's.
   Scope: the theme toggle, and copy-to-clipboard for pasteable blocks. */
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

/* ---------- copy to clipboard ----------
   The prompt is the product, so copying it must work everywhere — including the
   contexts where the modern API silently does not exist:

   - `navigator.clipboard` is undefined on plain http:// origins, which is how
     someone reading this over a LAN preview or a self-hosted mirror will see it;
   - it also rejects when the document is not focused, or when a permissions
     policy blocks it.

   Both paths fall through to the textarea + execCommand trick, which is
   deprecated and still the only thing that works in those cases. Every copy
   button names a target element with `data-copy`; the text is read from the DOM,
   so the bytes are never duplicated into a data attribute. */
(() => {
  const buttons = document.querySelectorAll('[data-copy]');
  if (!buttons.length) return;

  let toast;
  const say = (message, ok) => {
    if (!toast) {
      toast = document.createElement('div');
      toast.className = 'toast';
      toast.setAttribute('role', 'status');
      toast.setAttribute('aria-live', 'polite');
      document.body.appendChild(toast);
    }
    toast.textContent = message;
    toast.dataset.ok = ok ? 'yes' : 'no';
    toast.classList.add('is-visible');
    clearTimeout(say.timer);
    say.timer = setTimeout(() => toast.classList.remove('is-visible'), 2400);
  };

  const legacyCopy = (text) => {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      // Off-screen but focusable, and fixed so selecting it cannot scroll the page.
      ta.style.cssText = 'position:fixed;top:0;left:-9999px;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, text.length);
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch {
      return false;
    }
  };

  const copy = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch {
        /* not focused, blocked by policy, or user denied — fall through */
      }
    }
    return legacyCopy(text);
  };

  for (const btn of buttons) {
    btn.addEventListener('click', async () => {
      const target = document.querySelector(btn.dataset.copy);
      if (!target) return;

      const label = btn.dataset.copyLabel || 'Copy';
      const copied = btn.dataset.copiedLabel || 'Copied';
      const text = btn.querySelector('.copy-text');
      const ok = await copy(target.textContent);

      btn.dataset.state = ok ? 'copied' : 'failed';
      if (text) text.textContent = ok ? copied : 'Copy failed';
      say(
        ok
          ? `${btn.dataset.copyAnnounce || label} — copied to your clipboard.`
          : 'Copy failed. Select the text in the box and copy it yourself.',
        ok
      );

      clearTimeout(btn._resetTimer);
      btn._resetTimer = setTimeout(() => {
        delete btn.dataset.state;
        if (text) text.textContent = label;
      }, 2400);
    });
  }
})();

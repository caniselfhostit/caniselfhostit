// Every brand and domain string on the site lives here — nowhere else.
// (The sibling project hardcodes its domain across ~22 files; that fork tax
// gets paid exactly once, by this module existing.)

export const SITE = {
  domain: 'caniselfhostit.com',
  origin: 'https://caniselfhostit.com',
  name: 'Can I Self-Host It?',
  shortName: 'caniselfhostit',
  tagline: 'One prompt to get ready. One prompt per app.',
  promise: 'Every prompt assumes nothing is installed. Not even git.',
  description:
    'For every SaaS you pay for: a mature open-source replacement, and the exact AI-agent prompts that install it on your own server — starting from a machine with nothing on it.',
  // Campaign domain; 301s to the canonical origin (configured at the zone, Phase 3).
  redirectDomains: ['dontvibecodeit.com'],
  repoUrl: 'https://github.com/caniselfhostit/caniselfhostit',
  author: {
    name: 'Jashanpreet Singh',
    url: '/about/',
  },
  // Independent, credited sibling — a different operator, not a network.
  // Credit appears on /about and /methodology only (never sitewide footers).
  inspiredBy: { name: 'canivibecodeit.com', url: 'https://canivibecodeit.com' },
  // DataFast. This id is a PUBLIC identifier, not a credential: it ships in the
  // HTML of every page and only labels which property receives the pageview — it
  // cannot read the dashboard. An env var would hide it from this repo and from
  // nobody else, while adding a way for analytics to disappear silently the day
  // a CI variable goes missing. So it lives here, next to the domain it names.
  // Local dev stays silent on its own: DataFast ignores localhost unless
  // `data-allow-localhost` is set, and Base.astro never sets it.
  datafastWebsiteId: 'dfid_GJOfrnYegFWDR6tDjge8v',
  // The COOKIELESS build, deliberately — DataFast's default `script.js` sets a
  // cookie for visitor identification, and their own GDPR page says that one
  // "may need a cookie banner". /privacy is written against this exact file and
  // renders the URL verbatim, so swapping it back makes that page visibly lie.
  // Change the copy in the same commit or not at all (phase0-todos.md item D).
  datafastScriptUrl: 'https://datafa.st/js/script.cookieless.js',
};

// Title verdict word is DERIVED from the setup tier (PRD §0) — never hand-written.
export const TIER_VERDICTS = {
  'one-command': 'YES',
  'one-evening': 'YES',
  'one-weekend': 'YES, BUT',
  'ongoing-ops': 'YES, IF',
};

/** "Can I self-host Plausible? YES — one prompt, ~10 minutes (2026)" */
export function pageTitle(name, tier, minutes) {
  const year = new Date().getFullYear();
  const verdict = TIER_VERDICTS[tier] ?? 'YES';
  const time = minutes ? ` — one prompt, ~${minutes} minutes` : '';
  return `Can I self-host ${name}? ${verdict}${time} (${year})`;
}
